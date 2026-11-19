import Foundation
import Testing
@testable import MinisCore

/// Synthetic policy and workspace fixtures only; these tests launch no shell.
struct AlignedShellCommandContractTests {
    @Test func unsupportedGitSummaryPreservesOriginalApprovalIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("summary-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input: [String: Any] = ["command": "git commit --amend -m fix", "cwd": root.path]
        let gate = ApprovalGate()
        let before = gate.makeRequest(id: "same-call", tool: "shell_execute", input: input)
        let text = try await BuiltinToolExecutor(allowedRoot: root).prepareGitWriteSummary(input)
        #expect(text?.contains("此命令形式不支持") == true)
        #expect(text?.contains("差异统计：未能形成") == true)
        #expect(text?.contains("无差异统计（命令输出为空）") == false)
        let after = gate.makeRequest(id: "same-call", tool: "shell_execute", input: input)
        #expect(before.inputDigest == after.inputDigest)
        #expect(before.id == after.id)
        #expect(after.requiresApproval)
        #expect(input["command"] as? String == "git commit --amend -m fix")
        #expect(input["cwd"] as? String == root.path)
    }

    @Test func failedAndTimedOutGitReadsDiscloseRedactedFailureWithoutInventedStat() async throws {
        let secret = "synthetic-secret-value-123"
        let errors: [Error] = [
            GitWorkflowService.WorkflowError.commandFailed(command: "git status --short",
                exitCode: 128, stdout: "", stderr: "failed " + secret),
            URLError(.timedOut),
        ]
        for error in errors {
            let text = try await BuiltinToolExecutor.gitWriteApprovalPresentation(
                command: "git commit -m fix", directory: URL(fileURLWithPath: "/synthetic-repo"),
                snapshot: .default, knownSecrets: [secret]) { throw error }
            #expect(text.contains("摘要读取失败"))
            #expect(text.contains("差异统计：未能形成"))
            #expect(text.contains("仍按原命令与目录进行本次审批"))
            #expect(!text.contains(secret))
            #expect(!text.contains("无差异统计（命令输出为空）"))
        }
    }

    @Test func gitSummaryCancellationIsPropagatedWithoutPresentation() async throws {
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        do {
            _ = try await BuiltinToolExecutor.gitWriteApprovalPresentation(
                command: "git commit -m fix", directory: URL(fileURLWithPath: "/synthetic-repo"),
                snapshot: .default, knownSecrets: []) { throw cancelled }
            Issue.record("cancellation must not become approval presentation")
        } catch {
            #expect((error as NSError) === cancelled)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await BuiltinToolExecutor.gitWriteApprovalPresentation(
                command: "git commit -m fix", directory: URL(fileURLWithPath: "/synthetic-repo"),
                snapshot: .default, knownSecrets: []) { throw CancellationError() }
        }
    }

    @Test func deniedGitCommandNeverReachesSummaryReadOrApprovalPresentation() async throws {
        let snapshot = TerminalPolicySnapshot(settings: TerminalPolicySettings(userDeniedCommands: ["git"]))
        await #expect(throws: ToolExecutorError.self) {
            _ = try await BuiltinToolExecutor.gitWriteApprovalPresentation(
                command: "git commit -m fix", directory: URL(fileURLWithPath: "/synthetic-repo"),
                snapshot: snapshot, knownSecrets: []) {
                    Issue.record("denied command must not attempt summary reads")
                    throw URLError(.timedOut)
                }
        }
    }

    @Test func successfulGitSummaryKeepsActualEvidence() async throws {
        let text = try await BuiltinToolExecutor.gitWriteApprovalPresentation(
            command: "git commit -m fix", directory: URL(fileURLWithPath: "/synthetic-repo"),
            snapshot: .default, knownSecrets: []) {
                .init(command: "git commit -m fix", workingDirectory: "/synthetic-repo",
                    status: "M  real.swift", diffstat: "real.swift | 2 ++",
                    approvalText: "差异统计：real.swift | 2 ++")
            }
        #expect(text.contains("M  real.swift"))
        #expect(text.contains("差异统计：real.swift | 2 ++"))
        #expect(!text.contains("摘要不可用"))
    }

    @Test func unknownCommandStillRequiresApprovalButIsExecutableAfterApproval() throws {
        let command = "unregistered-project-tool --version"
        let gate = ApprovalGate(policy: .autoApprove)
        #expect(TerminalPolicySnapshot.default.classify(command: command) == .unknown)
        #expect(gate.shouldAsk(tool: "shell_execute", input: ["command": command]))
        try BuiltinToolExecutor.validateShellPolicy(command: command, snapshot: .default)
        let request = gate.makeRequest(tool: "shell_execute", input: ["command": command])
        #expect(!request.inputSummary.contains("即使批准也会拒绝"))
    }

    @Test func hardAndUserDenialsRemainEffective() throws {
        let policy = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: [], confirmationCommands: [], userDeniedCommands: ["blocked-tool"]))
        for command in ["halt whoami", "blocked-tool --version"] {
            #expect(throws: ToolExecutorError.self) {
                try BuiltinToolExecutor.validateShellPolicy(command: command, snapshot: policy)
            }
        }
    }

    @Test func explicitWorkingDirectoryUsesAuthorizedSubdirectory() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let child = root.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = BuiltinToolExecutor(allowedRoot: root)
        #expect(try executor.shellWorkingDirectory(["command": "npm test", "cwd": child.path]).path == child.path)
        #expect(try executor.shellWorkingDirectory(["command": "pwd"]).path == root.path)
        #expect(throws: ToolExecutorError.self) {
            try executor.shellWorkingDirectory(["command": "pwd", "cwd": "/"])
        }
    }

    /// 有的模型把可选参数全部填上，没有目录时给 cwd:""；按没给处理，沿用会话默认目录。
    @Test func emptyWorkingDirectoryMeansDefaultDirectory() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = BuiltinToolExecutor(allowedRoot: root)
        #expect(try executor.shellWorkingDirectory(["command": "pwd", "cwd": ""]).path == root.path)
        #expect(try executor.shellWorkingDirectory(["command": "pwd", "cwd": "  "]).path == root.path)
        #expect(PersistentApprovalRuleMatcher.evaluateShell(
            input: ["command": "swift test", "cwd": ""], defaultWorkingDirectory: root.path) == .pattern("swift test"))
        #expect(throws: ToolExecutorError.self) {
            try executor.shellWorkingDirectory(["command": "pwd", "cwd": "relative/dir"])
        }
    }

    @Test func explicitDirectoryDoesNotChangeTheNextCallAndRejectsEscapingSymlink() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let nested = root.appendingPathComponent("nested")
        let outside = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let executor = BuiltinToolExecutor(allowedRoot: root)
        #expect(try executor.shellWorkingDirectory(["command": "pwd", "cwd": nested.path]).path == nested.path)
        #expect(try executor.shellWorkingDirectory(["command": "pwd"]).path == root.path)
        #expect(throws: ToolExecutorError.self) {
            try executor.shellWorkingDirectory(["command": "pwd", "cwd": link.path])
        }
    }

    @Test func compoundCallsKeepPerCallApprovalAndCannotBecomePersistentRules() throws {
        for command in ["npm test && npm run build", "git diff | head", "npm test > out.log"] {
            // The minimal N2-05 contract allows explicit approval, not a broad
            // persistent wildcard granting every component of shell syntax.
            #expect(TerminalPolicySnapshot.default.classify(command: command) == .confirmation)
            #expect(ApprovalGate(policy: .autoApprove).shouldAsk(tool: "shell_execute", input: ["command": command]))
            try BuiltinToolExecutor.validateShellPolicy(command: command, snapshot: .default)
            // 只读 git 自动放行所用的判定仍然不接受复合语法。
            guard case .unavailable = PersistentApprovalRuleMatcher.evaluateShell(command: command) else {
                Issue.record("compound syntax must not be treated as one read-only command")
                continue
            }
        }
        // 对齐 Claude Code：以后都允许按子命令各自生成前缀；含重定向的写法不提供。
        #expect(PersistentApprovalRuleMatcher.evaluateShellRules(command: "npm test && npm run build")
            == .patterns(["npm test", "npm run build"]))
        #expect(PersistentApprovalRuleMatcher.evaluateShellRules(command: "npm test > out.log")
            != .patterns(["npm test"]))
    }

    @Test func standaloneCDExplainsTheExplicitDirectoryContract() throws {
        let executor = BuiltinToolExecutor(allowedRoot: URL(fileURLWithPath: "/synthetic-root"))
        do {
            _ = try executor.shellWorkingDirectory(["command": "cd package"])
            Issue.record("standalone cd must explain that directory state is not retained")
        } catch let error as ToolExecutorError {
            #expect(error.localizedDescription.contains("不保持目录"))
            #expect(error.localizedDescription.contains("cwd"))
        }
    }

    @Test func gitControlWritesRequireFreshApprovalEvenUnderDirectoryRules() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let hooks = root.appendingPathComponent(".git/hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ApprovalGate(policy: .autoApprove)
        for path in [root.appendingPathComponent(".git/config").path, hooks.appendingPathComponent("pre-commit").path] {
            #expect(gate.shouldAsk(tool: "file_write", input: ["path": path]))
            #expect(PersistentApprovalRuleMatcher.evaluateFile(capability: "file_write", input: ["path": path], roots: [hooks.path])
                == .unavailable("Git 控制文件每次都需询问"))
        }
    }

    @Test func deniedApprovalCardsWarnOnlyForCommandsTheSnapshotRejects() {
        var gate = ApprovalGate()
        gate.terminalPolicySnapshot = TerminalPolicySnapshot(settings: TerminalPolicySettings(userDeniedCommands: ["blocked-tool"]))
        for command in ["halt whoami", "blocked-tool"] {
            #expect(gate.makeRequest(tool: "shell_execute", input: ["command": command]).inputSummary.contains("即使批准也会拒绝"))
        }
        #expect(gate.makeRequest(tool: "shell_execute", input: ["command": "unregistered-tool"]).inputSummary.contains("批准后执行"))
    }

    @Test func changedCWDRequiresFreshApprovalAndIsIncludedInTheDigest() throws {
        let directory = "/synthetic/project"
        let command: [String: Any] = ["command": "swift test", "cwd": directory]
        #expect(PersistentApprovalRuleMatcher.evaluateShell(input: command, defaultWorkingDirectory: directory) == .pattern("swift test"))
        #expect(PersistentApprovalRuleMatcher.evaluateShell(input: command, defaultWorkingDirectory: directory + "/other")
            == .unavailable("工作目录与会话默认目录不同，每次都需询问"))
        let gate = ApprovalGate()
        let base = gate.makeRequest(tool: "shell_execute", input: command).inputDigest
        #expect(base != nil)
        #expect(base != gate.makeRequest(tool: "shell_execute", input: ["command": "swift test", "cwd": directory + "/other"]).inputDigest)
        #expect(base != gate.makeRequest(tool: "shell_execute", input: ["command": "swift test", "cwd": directory, "run_in_background": true]).inputDigest)
    }

    @Test func directUnknownWithoutFreshReceiptIsRejectedBeforeSpawn() async throws {
        let executor = BuiltinToolExecutor(allowedRoot: URL(fileURLWithPath: "/synthetic-root"))
        await #expect(throws: ToolExecutorError.approvalRequired("shell_execute")) {
            try await executor.execute(name: "shell_execute", input: ["command": "unregistered-project-tool"])
        }
    }

    @Test func changedUnknownCallCannotBorrowAnotherInputsFreshReceipt() async throws {
        let original: [String: Any] = ["command": "unregistered-project-tool", "cwd": "/synthetic/project", "run_in_background": false]
        let executor = BuiltinToolExecutor(allowedRoot: URL(fileURLWithPath: "/synthetic/project"))
        _ = try await withFreshShellApprovalForTest(input: original) {
            // Positive control exercises the same receipt projection without spawning.
            #expect(ApprovedShellCallScope.permits(input: original))
            let changedInputs: [[String: Any]] = [
                ["command": "another-unregistered-tool", "cwd": "/synthetic/project", "run_in_background": false],
                ["command": "unregistered-project-tool", "cwd": "/synthetic/other", "run_in_background": false],
                ["command": "unregistered-project-tool", "cwd": "/synthetic/project", "run_in_background": true],
            ]
            for input in changedInputs {
                #expect(!ApprovedShellCallScope.permits(input: input))
                await #expect(throws: ToolExecutorError.approvalRequired("shell_execute")) {
                    try await executor.execute(name: "shell_execute", input: input)
                }
            }
            return ""
        }
    }

    @Test func explicitCWDWithUnknownSessionDefaultCannotBeRemembered() {
        #expect(PersistentApprovalRuleMatcher.evaluateShell(
            input: ["command": "swift test", "cwd": "/synthetic/project"], defaultWorkingDirectory: nil)
            == .unavailable("工作目录与会话默认目录不同，每次都需询问"))
    }

    @Test func gitReadOnlyConsumerHonorsExplicitAskAndUserDenial() {
        let input: [String: Any] = ["command": "git status"]
        #expect(TerminalPolicySnapshot.default.classify(command: "git status") == .allowed)
        #expect(!ApprovalGate().shouldAsk(tool: "shell_execute", input: input))
        #expect(!ApprovalGate(policy: .riskOnlyAsk).shouldAsk(tool: "shell_execute", input: input))
        #expect(ApprovalGate(policy: .alwaysAsk).shouldAsk(tool: "shell_execute", input: input))
        #expect(ApprovalGate().shouldAsk(tool: "shell_execute", input: ["command": "git commit -m update"]))
        var denied = ApprovalGate()
        denied.terminalPolicySnapshot = TerminalPolicySnapshot(settings: TerminalPolicySettings(userDeniedCommands: ["git"]))
        #expect(denied.shouldAsk(tool: "shell_execute", input: input))
        #expect(denied.terminalPolicySnapshot.classify(command: "git status") == .denied)
        #expect(denied.makeRequest(tool: "shell_execute", input: input).inputSummary.contains("即使批准也会拒绝"))
    }

    @Test func retainedShellOutputIsStoredAndPRFieldsReachTheToolResult() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = BuiltinToolExecutor(allowedRoot: root)
        let storageRoot = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let session = ToolOutputArtifactSessionScope(sessionStorageRoot: storageRoot, sessionID: UUID())
        let output = String(repeating: "已脱敏输出", count: 6_001)
        let raw = try ToolOutputArtifactSessionScope.$current.withValue(session) {
            try executor.shellResult(command: "git status", exitCode: 7, stdout: output, stderr: "failure")
        }
        let object = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        #expect(object["exit_code"] as? Int == 7)
        #expect(object["stderr"] as? String == "failure")
        #expect(((object["stdout"] as? String)?.count ?? 0) < output.count)
        let artifact = try #require(object["stdout_artifact"] as? [String: Any])
        #expect(artifact["capture_scope"] as? String == "retained_shell_output")
        let path = try #require(artifact["path"] as? String)
        #expect(path.hasPrefix(storageRoot.appendingPathComponent("tool-output").path + "/"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".miniscanvas").path))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == output)
        #expect(object["git_workflow_instructions"] as? String == GitWorkflowPolicy.workflowInstructions)
        let pr = try executor.shellResult(command: "gh pr view --json url,state", exitCode: 0,
            stdout: "{\"url\":\"https://github.com/synthetic/project/pull/42\",\"state\":\"OPEN\"}", stderr: "")
        let prObject = try #require(JSONSerialization.jsonObject(with: Data(pr.utf8)) as? [String: Any])
        let fields = try #require(prObject["git_workflow"] as? [String: String])
        #expect(fields["git_pr_state"] == "OPEN")
        #expect(fields["git_pr_url"] == "https://github.com/synthetic/project/pull/42")
    }

    @Test func outputWriteFailurePreservesTimeoutAndReportsTheFailedArtifact() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A file blocks the private session artifact directory; no permissions or sleep needed.
        let storageRoot = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: storageRoot.appendingPathComponent("tool-output"))
        let executor = BuiltinToolExecutor(allowedRoot: root)
        let session = ToolOutputArtifactSessionScope(sessionStorageRoot: storageRoot, sessionID: UUID())
        let error = ToolOutputArtifactSessionScope.$current.withValue(session) {
            executor.shellTimeoutError(seconds: 2, stdout: Data(String(repeating: "x", count: 30_001).utf8), stderr: Data())
        }
        guard case .shellTimeout(let detail) = error else {
            Issue.record("artifact failure must preserve shellTimeout")
            return
        }
        #expect(detail.contains("输出落盘失败"))
        #expect(!detail.contains("已提供的输出已保存"))
    }

    @Test func largeOutputWithoutAdmittedSessionStorageFailsInsteadOfWritingToProject() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = BuiltinToolExecutor(allowedRoot: root)
        #expect(throws: ToolExecutorError.toolNotConfigured("会话输出存储")) {
            try ToolOutputArtifactSessionScope.$current.withValue(nil) {
                try executor.shellResult(command: "echo synthetic", exitCode: 0,
                    stdout: String(repeating: "x", count: 30_001), stderr: "")
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func parallelAdmittedSessionsKeepTheirOwnPrivateOutputDirectories() async throws {
        let fixture = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let sessions = [ToolOutputArtifactSessionScope(sessionStorageRoot: fixture.appendingPathComponent("a"), sessionID: UUID()),
                        ToolOutputArtifactSessionScope(sessionStorageRoot: fixture.appendingPathComponent("b"), sessionID: UUID())]
        let paths = try await withThrowingTaskGroup(of: String.self) { group in
            for session in sessions {
                group.addTask {
                    let executor = BuiltinToolExecutor(allowedRoot: fixture.appendingPathComponent("project"))
                    return try ToolOutputArtifactSessionScope.$current.withValue(session) {
                        let raw = try executor.shellResult(command: "echo synthetic", exitCode: 0,
                            stdout: String(repeating: "x", count: 30_001), stderr: "")
                        let object = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
                        let artifact = try #require(object["stdout_artifact"] as? [String: Any])
                        let path = try #require(artifact["path"] as? String)
                        #expect(path.hasPrefix(ToolOutputArtifactStore.directory(
                            sessionStorageRoot: session.sessionStorageRoot, sessionID: session.sessionID).path + "/"))
                        return path
                    }
                }
            }
            var result: [String] = []
            for try await path in group { result.append(path) }
            return result
        }
        #expect(Set(paths).count == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.appendingPathComponent("project").path))
        let inherited = await ToolOutputArtifactSessionScope.$current.withValue(sessions[0]) {
            await Task { ToolOutputArtifactSessionScope.current?.sessionID }.value
        }
        #expect(inherited == sessions[0].sessionID)
    }

    @Test func producedOutputReadsUseExistingPagingWithoutGrantingPrivateStorage() async throws {
        let base = try FormalTestIsolationPaths.resolveCurrentProcess()?.rootDirectory
            ?? FileManager.default.temporaryDirectory
        let fixture = base.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let project = fixture.appendingPathComponent("project")
        let storage = fixture.appendingPathComponent("private-session-storage")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let executor = BuiltinToolExecutor(allowedRoot: project, appPrivateDeniedRoots: [storage])
        #expect(executor.explicitDeniedRoots.isEmpty)
        #expect(executor.deniedRoots.map(\.path) == [storage.path])
        let explicitlyDenied = BuiltinToolExecutor(allowedRoot: project, deniedRoots: [storage], appPrivateDeniedRoots: [storage])
        #expect(explicitlyDenied.explicitDeniedRoots.map(\.path) == [storage.path])
        let session = ToolOutputArtifactSessionScope(sessionStorageRoot: storage, sessionID: UUID())
        let artifactPath = try await ToolOutputArtifactSessionScope.$current.withValue(session) {
            let output = (1...7_000).map { "line \($0)" }.joined(separator: "\n")
            let raw = try executor.shellResult(command: "echo synthetic", exitCode: 0, stdout: output, stderr: "")
            let object = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            let artifact = try #require(object["stdout_artifact"] as? [String: Any])
            let path = try #require(artifact["path"] as? String)
            let page = try await executor.execute(name: "file_read", input: ["path": path, "offset": 2, "lines": 2, "max_length": 200])
            #expect(page == "     2\tline 2\n     3\tline 3")
            await #expect(throws: ToolExecutorError.pathViolation(path)) {
                try await explicitlyDenied.execute(name: "file_read", input: ["path": path])
            }
            let unknownDenialSource = ChildToolWorkspaceScope(readRoots: [project.path], writeRoots: [project.path],
                workingDirectory: project.path, deniedRoots: [storage.path], parentAuthorityCheck: nil)
            await ChildToolWorkspaceScope.$current.withValue(unknownDenialSource) {
                await #expect(throws: ToolExecutorError.pathViolation(path)) {
                    try await executor.execute(name: "file_read", input: ["path": path])
                }
            }
            let privateFile = storage.appendingPathComponent("private.txt")
            try Data("unrelated app state".utf8).write(to: privateFile)
            await #expect(throws: ToolExecutorError.self) {
                try await executor.execute(name: "file_read", input: ["path": privateFile.path])
            }
            return path
        }
        let otherSession = ToolOutputArtifactSessionScope(sessionStorageRoot: storage, sessionID: UUID())
        await ToolOutputArtifactSessionScope.$current.withValue(otherSession) {
            await #expect(throws: ToolExecutorError.self) {
                try await executor.execute(name: "file_read", input: ["path": artifactPath])
            }
        }
        await ToolOutputArtifactSessionScope.$current.withValue(nil) {
            await #expect(throws: ToolExecutorError.self) {
                try await executor.execute(name: "file_read", input: ["path": artifactPath])
            }
        }
    }

    @Test func machineErrorCodesStayStableWhileDisplayTextIsChinese() {
        #expect(ToolExecutorError.modelModeUnverified.localizedDescription == "MODEL_MODE_UNVERIFIED")
        #expect(ToolExecutorError.resourceScopeInvalid.localizedDescription == "TASK_RESOURCE_SCOPE_INVALID")
        #expect(ToolExecutorError.modelModeUnverified.displayDescription.contains("模型配置"))
        #expect(ToolExecutorError.resourceScopeInvalid.displayDescription.contains("授权目录"))
    }

    @Test func chineseErrorsRedactEmbeddedCredentials() {
        let description = ToolExecutorError.shellRejected("Authorization: Bearer synthetic-secret-token-123456789").localizedDescription
        #expect(description.hasPrefix("终端命令已被拒绝："))
        #expect(!description.contains("synthetic-secret-token-123456789"))
        #expect(ToolExecutorError.approvalRequired("shell_execute").localizedDescription.contains("需要审批"))
    }
}

/// Existing Gate mints the receipt used by these post-approval executor fixtures.
func withFreshShellApprovalForTest(input: [String: Any], operation: () async throws -> String) async throws -> String {
    let capture = ApprovedShellReceiptCapture()
    var gate = ApprovalGate(delegate: FreshShellTestDelegate())
    gate.onApprovalReceipt = { capture.record($0) }
    let context = ApprovalAuthorizationContext(actorID: "shell-fixture", sessionID: "shell-fixture-session",
        turnID: 1, taskID: "shell-fixture-task", runID: "shell-fixture-run", attemptID: UUID().uuidString,
        effectID: UUID().uuidString, scope: "request", payloadDigest: try #require(ApprovalAuthorizationContext.payloadDigest(for: input)),
        expiresAt: Date().addingTimeInterval(30), policyRevision: "shell-fixture-policy",
        grantEpoch: "shell-fixture-epoch", toolName: "shell_execute")
    _ = try await gate.gate(tool: "shell_execute", input: input, context: context)
    let capturedReceipt: ApprovalReceipt = try #require(capture.load())
    return try await ApprovedShellCallScope.$currentLegacyReceipt.withValue(capturedReceipt) {
        try await operation()
    }
}

private struct FreshShellTestDelegate: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(approved: true, confirmed: true, requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}
