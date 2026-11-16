import Foundation
import Testing
@testable import MinisCore

@Suite("H03 model shell environment — synthetic inputs only")
struct ModelShellEnvironmentTests {
    @Test func exportedSnapshotKeepsPathEqualsAndNewlines() throws {
        let bytes = Data("startup banner\n\0MINISCANVAS_LOGIN_ENV\0PATH=/synthetic/nvm/bin:/synthetic/cargo/bin:/bin\0GH_TOKEN=synthetic=value\nsecond-line\0SSH_AUTH_SOCK=/synthetic/agent\0".utf8)
        let environment = try #require(ModelShellEnvironment.decodeSnapshot(bytes))
        #expect(environment["PATH"] == "/synthetic/nvm/bin:/synthetic/cargo/bin:/bin")
        #expect(environment["GH_TOKEN"] == "synthetic=value\nsecond-line")
        #expect(environment["SSH_AUTH_SOCK"] == "/synthetic/agent")
    }

    @Test func credentialsPassByDefaultAndStripOptionPreservesIsolation() {
        let snapshot = ["PATH": "/synthetic/nvm/bin:/bin", "HOME": "/synthetic/original",
                        "TMPDIR": "/synthetic/tmp", "GH_TOKEN": "synthetic-token",
                        "SSH_AUTH_SOCK": "/synthetic/agent", "LANG": "en_US.UTF-8", "CI": "synthetic-parent-value"]
        let defaults = ModelShellEnvironment.values(snapshot: snapshot, stripCredentials: false,
            noninteractive: true, directories: ("/owned/profile/home", "/owned/profile/tmp"))
        #expect(defaults["PATH"] == snapshot["PATH"])
        #expect(defaults["GH_TOKEN"] == snapshot["GH_TOKEN"])
        #expect(defaults["SSH_AUTH_SOCK"] == snapshot["SSH_AUTH_SOCK"])
        #expect(defaults["HOME"] == "/owned/profile/home")
        #expect(defaults["TMPDIR"] == "/owned/profile/tmp")
        #expect(defaults["GIT_TERMINAL_PROMPT"] == "0")
        #expect(defaults["GIT_EDITOR"] == "true")
        #expect(defaults["GIT_PAGER"] == "cat")
        #expect(defaults["PAGER"] == "cat")
        #expect(defaults["CI"] == "synthetic-parent-value")
        let stripped = ModelShellEnvironment.values(snapshot: snapshot, stripCredentials: true,
            noninteractive: false, directories: ("/owned/profile/home", "/owned/profile/tmp"))
        #expect(stripped["GH_TOKEN"] == nil)
        #expect(stripped["SSH_AUTH_SOCK"] == nil)
        #expect(stripped["PATH"] == snapshot["PATH"])
        #expect(stripped["HOME"] == "/owned/profile/home")
        #expect(stripped["CI"] == "synthetic-parent-value")
    }

    @Test func oldSettingsDecodeCredentialPassThroughAndPersistOptOut() throws {
        var settings = try JSONDecoder().decode(AgentSettings.self, from: Data("{}".utf8))
        #expect(!settings.stripModelShellCredentials)
        #expect(settings.modelShellNoninteractive)
        settings.stripModelShellCredentials = true
        settings.modelShellNoninteractive = false
        let restored = try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.stripModelShellCredentials)
        #expect(!restored.modelShellNoninteractive)
    }

    @Test func environmentDumpStillRequiresApprovalWithPersistedOldAllowlist() {
        let snapshot = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: ["env", "printenv"], confirmationCommands: []))
        #expect(snapshot.classify(command: "env") == .confirmation)
        #expect(snapshot.classify(command: "printenv GH_TOKEN") == .confirmation)
        let denied = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: ["env"], confirmationCommands: [], userDeniedCommands: ["env"]))
        #expect(denied.classify(command: "env") == .denied)
    }

    @Test func gitleaksFormatsRedactBareTokensAndKeepOrdinaryOutput() {
        let github = "ghp_" + String(repeating: "Q", count: 36)
        let aws = "AKIA" + String(repeating: "Z", count: 16)
        let text = "before \(github) / \(aws) after"
        let masked = ContentSecretRedactor.redact(ContentSecretRedactor.FormatCheckedText(text))
        #expect(masked == "before \(ContentSecretRedactor.mask(github)) / \(ContentSecretRedactor.mask(aws)) after")
        #expect(TerminalProcessResult(exitCode: 0, stdout: github, stderr: aws).stdout == ContentSecretRedactor.mask(github))
        #expect(ContentSecretRedactor.redact("version 1.2.3 /synthetic/project") == "version 1.2.3 /synthetic/project")
    }

    @Test func unknownCommandUsesSameApprovalBoundaryAsVisibleTerminal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("H03-synthetic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = TerminalExecutionContext(sessionID: "synthetic-session", turnID: "turn", taskID: "task",
                                               projectID: "project", workdir: root.path)
        let now = Date()
        let runner = H03SyntheticTerminalRunner()
        let boundary = TerminalBoundary(policy: TerminalPolicy(scopeID: "project", allowedRoot: root,
                                                               now: { now }), runner: runner)
        let request = TerminalExecutionRequest(capabilityID: "shell_execute", command: "synthetic_unregistered",
                                               context: context, timeout: .seconds(1))
        let waiting = await boundary.execute(request)
        #expect(waiting.error == TerminalBoundaryError.approvalRequired.rawValue)
        let approval = TerminalApproval(scopeID: "project", requestFingerprint: request.requestFingerprint,
                                        expiresAt: now.addingTimeInterval(60))
        let approved = TerminalExecutionRequest(capabilityID: "shell_execute", command: request.command,
                                                context: context, approval: approval, timeout: .seconds(1))
        let receipt = await boundary.execute(approved)
        #expect(receipt.error == nil)
        #expect(receipt.exitCode == 0)
        #expect(receipt.output.contains("synthetic output"))
    }

    private static let shortSwitchSnapshot = [
        "CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH": "1", "FEATURE_TOKEN_ENABLED": "true",
        "GH_TOKEN": "ghp_synthetic0123456789abcdef", "PATH": "/usr/bin:/bin"]

    @Test func shortSwitchValuesAreNotTreatedAsKnownSecrets() {
        let values = ModelShellEnvironment.knownCredentialValues(snapshot: Self.shortSwitchSnapshot)
        #expect(Set(values) == ["ghp_synthetic0123456789abcdef"])
    }

    @Test func shortSwitchValueDoesNotCorruptRedactedText() {
        let values = ModelShellEnvironment.knownCredentialValues(snapshot: Self.shortSwitchSnapshot)
        let text = "/var/folders/gl/tlblp4pn14zfrk/T/G22_J01_kuFZs/data/config.json ratio 0.1 items [1,2,3] key ghp_synthetic0123456789abcdef"
        let output = ContentSecretRedactor.redact(text, knownSecrets: values)
        #expect(output.contains("tlblp4pn14zfrk"))
        #expect(output.contains("G22_J01_kuFZs"))
        #expect(output.contains("0.1"))
        #expect(output.contains("[1,2,3]"))
        #expect(!output.contains("ghp_synthetic0123456789abcdef"))
    }

    @Test func longCredentialValuesRemainKnownSecrets() {
        #expect(ModelShellEnvironment.knownCredentialValues(snapshot: ["GH_TOKEN": "abcde"]) == ["abcde"])
    }
}

private struct H03SyntheticTerminalRunner: TerminalProcessRunner {
    func run(command: String, workdir: URL, timeout: Duration) async throws -> TerminalProcessResult {
        TerminalProcessResult(exitCode: 0, stdout: "synthetic output", stderr: "")
    }
}
