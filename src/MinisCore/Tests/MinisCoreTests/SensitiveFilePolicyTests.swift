import Foundation
import Testing
@testable import MinisCore

@Suite("Goal18 shared sensitive file list")
struct SensitiveFilePolicyTests {
    @Test func externalCLILoginFilesAreCredentialPathsForReadsAndWrites() {
        let home = "/synthetic-goal23-home"
        for file in [".codex/auth.json", ".claude/.credentials.json"] {
            let path = home + "/" + file
            #expect(SensitiveFilePolicy.isCredentialPath(path, home: home), "\(file)")
            #expect(SensitiveFilePolicy.isCredentialPath(path, home: home, directoriesOnly: true), "\(file)")
        }
    }

    @Test func bypassShellRejectsExternalCLILoginFileLiterals() {
        let home = "/synthetic-goal23-home"
        for command in [
            "cat ~/.codex/auth.json",
            "cat \"$HOME/.claude/.credentials.json\"",
            "cat '\(home)/.codex/auth.json'",
        ] {
            #expect(SensitiveFilePolicy.credentialShellViolation(command: command, home: home) != nil, "\(command)")
        }
    }

    @Test func externalCLITranscriptsAndSimilarNamesStayOutsideCredentialProtection() {
        let home = "/synthetic-goal23-home"
        for file in [
            ".codex/sessions/rollout.jsonl",
            ".claude/projects/workspace/session.jsonl",
            ".codex/auth.json.example",
        ] {
            #expect(!SensitiveFilePolicy.isCredentialPath(home + "/" + file, home: home), "\(file)")
            #expect(SensitiveFilePolicy.credentialShellViolation(command: "cat ~/" + file, home: home) == nil, "\(file)")
        }
    }

    @Test func settingsDirectoryMentionsCanReachTheRealShellForAnOrdinaryCommand() async throws {
        let root = try minisCoreToolContractRoot("group6-hook-shell-normal")
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings")
        let hooksDirectory = settings.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
        let rules = PersistentApprovalRuleStore(fileURL: settings.appendingPathComponent("approval-rules.json"),
            homeDirectory: root.appendingPathComponent("unused-home").path)
        let hooks = HookConfigStore(directory: hooksDirectory)
        defer { withExtendedLifetime((rules, hooks)) {} }
        #expect(SensitiveFilePolicy.isProtectedStatePath(settings.path))
        #expect(SensitiveFilePolicy.isProtectedStatePath(hooksDirectory.path))
        let notes = settings.appendingPathComponent("notes.txt")
        let command = "printf '%s' '\(notes.path)'"
        let policy = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: ["printf"], confirmationCommands: [], userDeniedCommands: []))
        let executor = BuiltinToolExecutor(allowedRoot: root, terminalPolicySnapshot: policy)
        let output = try await executor.execute(name: "shell_execute", input: ["command": command, "timeout": 2])
        let json = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(json["exit_code"] as? Int == 0)
        #expect(json["stdout"] as? String == notes.path)
    }

    @Test func realShellEntryRejectsBothRegisteredHookFilesBeforeLaunching() async throws {
        let root = try minisCoreToolContractRoot("group6-hook-shell-protection")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hooks = HookConfigStore(directory: directory)
        defer { withExtendedLifetime(hooks) {} }
        let executor = BuiltinToolExecutor(allowedRoot: root)
        for name in [HookConfigStore.userFileName, HookConfigStore.trustFileName] {
            let target = directory.appendingPathComponent(name)
            do {
                _ = try await executor.execute(name: "shell_execute", input: ["command": "printf x > '\(target.path)'"])
                Issue.record("registered hook file command reached the shell")
            } catch ToolExecutorError.shellRejected(let reason) {
                #expect(reason == "不允许命令访问受保护的应用状态")
            }
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
    }

    @Test func bypassShellStillRejectsTheRuleFileAndBothRegisteredBackups() async throws {
        let root = try minisCoreToolContractRoot("group6-rule-shell-protection")
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings")
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        let file = settings.appendingPathComponent("approval-rules.json")
        let rules = PersistentApprovalRuleStore(fileURL: file,
            homeDirectory: root.appendingPathComponent("unused-home").path)
        defer { withExtendedLifetime(rules) {} }
        let executor = BuiltinToolExecutor(allowedRoot: root)
        for target in [file, file.appendingPathExtension("corrupt"), file.appendingPathExtension("unrecognized")] {
            do {
                _ = try await BypassOpenScope.$isActive.withValue(true) {
                    try await executor.execute(name: "shell_execute", input: ["command": "printf x > '\(target.path)'"])
                }
                Issue.record("bypass command reached a registered approval state file")
            } catch ToolExecutorError.shellRejected(let reason) {
                #expect(reason == "不允许命令访问受保护的应用状态")
            }
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
    }

    @Test func everyContractSensitiveFamilyIsHidden() {
        let paths = ["/test/.env", "/test/.env.production", "/test/id_rsa", "/test/id_ed25519",
            "/test/server.pem", "/test/PRIVATE.PEM", "/test/server.key", "/test/archive.p12",
            "/test/.ssh/config", "/test/.aws/config", "/test/.gnupg/trustdb.gpg",
            "/test/login.keychain-db", "/test/credentials", "/test/cookies",
            "/test/.envrc", "/test/credentials.json",
            "/test/credentials.backup/token", "/test/Cookies.sqlite", "/test/Library/Cookies/session.db",
            "/test/Library/Keychains/login-db", "/test/.ssh", "/test/.ssh/id_rsa.pub",
            "/test/credentials/../notes.txt"]
        for path in paths {
            #expect(SensitiveFilePolicy.contains(path))
            #expect(SensitiveFilePolicy.isSensitive(URL(fileURLWithPath: path)))
        }
    }

    @Test func ordinaryNamesAreNotSilentlyBlocked() {
        for path in ["/test/notes.txt", "/test/environment.md", "/test/keynote.txt", "/test/server.pem.backup.txt",
            "/test/mycredentials.json", "/test/notes.cookies.txt", "/test/not.envrc",
            "/test/ssh-notes/config", "/test/keyboard/notes.txt",
            "/test/.environment/cache", "/test/.env-hidden/../notes.txt"] {
            #expect(!SensitiveFilePolicy.contains(path))
            #expect(!SensitiveFilePolicy.isSensitive(URL(fileURLWithPath: path)))
        }
    }
}
