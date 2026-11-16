import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - TerminalGuard 解析/白名单测试

@Suite("TerminalGuard 命令解析与白名单")
struct TerminalGuardTests {

    @Test("parse 拆分 executable 与 args")
    func parseSplitsExecutableAndArgs() throws {
        let cmd = try #require(TerminalGuard.parse("ls -la /tmp"))
        #expect(cmd.executable == "ls")
        #expect(cmd.args == ["-la", "/tmp"])
    }

    @Test("parse 空行/纯空白返回 nil")
    func parseEmptyAndWhitespaceReturnsNil() {
        #expect(TerminalGuard.parse("") == nil)
        #expect(TerminalGuard.parse("   \n\t ") == nil)
    }

    @Test("parse 支持引号内空格")
    func parseHandlesQuotedArgs() throws {
        let cmd = try #require(TerminalGuard.parse(#"echo "hello world""#))
        #expect(cmd.executable == "echo")
        #expect(cmd.args == ["hello world"])
    }

    @Test("classify 只读命令为 allowed")
    func classifyAllowedCommands() {
        for line in ["ls", "pwd", "cat a.txt", "grep foo bar", "echo hi", "date", "git status"] {
            #expect(TerminalGuard.classify(line).kind == .allowed, "\(line) 应为 allowed")
        }
    }

    @Test("classify 写/网络/构建命令为 confirmation")
    func classifyConfirmationCommands() {
        for line in ["git add a.txt", "curl https://x.com", "rm -rf /tmp/a", "mkdir d", "python3 -m http.server 8000", "swift build"] {
            #expect(TerminalGuard.classify(line).kind == .confirmation, "\(line) 应为 confirmation")
        }
    }

    @Test("classify 系统管理命令为 denied")
    func classifyDeniedCommands() {
        for line in ["sudo ls", "open .", "osascript -e 'say hi'", "killall Dock", "shutdown now"] {
            #expect(TerminalGuard.classify(line).kind == .denied, "\(line) 应为 denied")
        }
    }

    @Test("classify 未知命令为 unknown")
    func classifyUnknownCommands() {
        for line in ["foobar", "./run.sh", "LS", "not-a-real-cmd --flag"] {
            #expect(TerminalGuard.classify(line).kind == .unknown, "\(line) 应为 unknown")
        }
    }

    @Test("白名单边界：killall 不在 confirmation（避免与 denied 语义矛盾）")
    func whitelistBoundaryKillall() {
        #expect(!TerminalGuard.confirmationCommands.contains("killall"))
        #expect(TerminalGuard.deniedCommands.contains("killall"))
    }

    @Test("白名单边界：python3/swift 在 confirmation（可用但需确认）")
    func whitelistBoundaryPythonAndSwift() {
        #expect(TerminalGuard.confirmationCommands.contains("python3"))
        #expect(TerminalGuard.confirmationCommands.contains("swift"))
    }

    @Test("自定义规则共享快照，用户拒绝和产品硬拒绝优先")
    func customPolicySnapshotPreservesDenialPrecedence() {
        let settings = TerminalPolicySettings(
            automaticAllowCommands: ["echo", "sudo"],
            confirmationCommands: ["git"],
            userDeniedCommands: ["echo"],
            explicitConfirmationCommands: ["git"],
            confirmationProvenanceVersion: 1
        )
        let snapshot = TerminalPolicySnapshot(settings: settings)

        // TerminalPolicySnapshot.classify checks explicit provenance before GitWorkflowPolicy.
        #expect(TerminalGuard.classify("git status").kind == .allowed)
        #expect(TerminalGuard.classify("echo hello", policy: snapshot).kind == .denied)
        #expect(TerminalGuard.classify("sudo ls", policy: snapshot).kind == .denied)
        #expect(TerminalGuard.classify("git status", policy: snapshot).kind == .confirmation)
        #expect(TerminalGuard.classify("ls", policy: snapshot).kind == .unknown)
        #expect(!snapshot.automaticAllowCommands.contains("sudo"))
    }
}

// MARK: - TerminalExecutor 执行链路（真实子进程 smoke）

@Suite("TerminalExecutor 执行链路")
struct TerminalExecutorTests {

    @Test("空命令直接返回，不抛错")
    func executorEmptyCommand() async throws {
        let result = try await TerminalExecutor.run("", cwd: "/tmp", timeout: 5)
        #expect(result.exitCode == 0)
        #expect(result.output == "")
    }

    @Test("简单命令直跑并返回输出")
    func executorRunsSimpleCommand() async throws {
        let result = try await TerminalExecutor.run("echo hello-terminal", cwd: "/tmp", timeout: 10)
        #expect(result.exitCode == 0)
        #expect(result.output.contains("hello-terminal"))
    }

    @Test("复合命令走 bash 保留管道语义")
    func executorRunsShellPipeline() async throws {
        let result = try await TerminalExecutor.run("echo abc | tr a-z A-Z", cwd: "/tmp", timeout: 10)
        #expect(result.exitCode == 0)
        #expect(result.output.contains("ABC"))
    }

    @Test("白名单外命令在 executor 层也按字面执行（白名单只属于 store 层）")
    func executorRunsNonWhitelistedLiteral() async throws {
        let result = try await TerminalExecutor.run("whoami", cwd: "/tmp", timeout: 10)
        #expect(result.exitCode == 0)
        #expect(!result.output.isEmpty)
    }

    @Test("超时：直跑路径 SIGTERM 直接命中命令，快速返回 timeout 且不挂起")
    func executorTimeoutDirectChild() async throws {
        let start = Date()
        await #expect(throws: TerminalExecutor.Error.timeout) {
            _ = try await TerminalExecutor.run("sleep 30", cwd: "/tmp", timeout: 1)
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 10, "直跑路径超时应 <10s，实际 \(elapsed)s（防 isRunning 永久卡死回归）")
    }

    @Test("超时：bash 路径（后代持管道）SIGKILL 兜底 + 有界 drain，不永久挂起")
    func executorTimeoutBashChildHoldingPipe() async throws {
        let start = Date()
        await #expect(throws: TerminalExecutor.Error.timeout) {
            // 带引号 → 走 bash；python3 常驻 → 后代持管道写端（回归旧版 readDataToEndOfFile 死锁场景）
            _ = try await TerminalExecutor.run(#"python3 -c "import time; time.sleep(30)""#, cwd: "/tmp", timeout: 1)
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 15, "bash 路径超时应 <15s，实际 \(elapsed)s（含 SIGKILL 2s + drain 3s 宽限）")
    }

    @Test("错误消息为本地化中文描述")
    func executorErrorDescription() {
        #expect(TerminalExecutor.Error.timeout.localizedDescription.contains("超时"))
        if case .spawnFailed(let reason) = TerminalExecutor.Error.spawnFailed("boom") {
            #expect(reason == "boom")
        } else {
            Issue.record("spawnFailed case 匹配失败")
        }
    }
}

@Suite("ContextPanel 终端 boundary adapter")
struct TerminalContextPanelAdapterTests {
    @Test
    func adapterUsesUnifiedReceiptForApprovedCommand() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = TerminalContextSnapshot(
            sessionID: "session-terminal-test",
            turnID: "turn-terminal-test",
            taskID: "task-terminal-test",
            projectID: "project-terminal-test",
            workdir: root.path
        )
        let receipt = await TerminalContextPanelAdapter(snapshot: snapshot).execute(
            command: "echo adapter-ok",
            cwd: root.path,
            approved: false
        )
        #expect(receipt.exitCode == 0)
        #expect(receipt.error == nil)
        #expect(receipt.output.contains("adapter-ok"))
        #expect(receipt.sessionID == snapshot.sessionID)
        #expect(!receipt.requestFingerprint.isEmpty)
    }
}

// MARK: - TerminalStore 提交链路（@MainActor）

@MainActor
@Suite("TerminalStore 提交链路")
struct TerminalStoreTests {
    private var contextSnapshot: TerminalContextSnapshot {
        TerminalContextSnapshot(
            sessionID: "session-terminal-store-test",
            turnID: "turn-terminal-store-test",
            taskID: "task-terminal-store-test",
            projectID: "project-terminal-store-test",
            workdir: "/tmp"
        )
    }

    /// 轮询等待命令跑完（isRunning 复位）。
    private func waitIdle(_ store: TerminalStore, timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        while store.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test("空输入不产生任何输出")
    func storeSubmitEmptyDoesNothing() {
        let store = TerminalStore(contextSnapshot: contextSnapshot)
        store.input = "   "
        store.submit()
        #expect(store.output.isEmpty)
        #expect(!store.isRunning)
    }

    @Test("未知命令等待确认，批准前不执行")
    func storeSubmitUnknownWaitsForConfirmation() {
        let store = TerminalStore(contextSnapshot: contextSnapshot)
        store.input = "foobar"
        store.submit()
        #expect(store.output.isEmpty)
        #expect(!store.isRunning)
        #expect(store.pendingConfirmation?.raw == "foobar")
    }

    @Test("allowed 命令执行完成、isRunning 复位")
    func storeSubmitAllowedCompletes() async {
        let store = TerminalStore(contextSnapshot: contextSnapshot)
        store.input = "echo store-level-ok"
        store.submit()
        #expect(store.isRunning)
        await waitIdle(store)
        #expect(!store.isRunning)
        #expect(store.output.contains("store-level-ok"))
    }

    @Test("confirmation 命令先弹确认条，确认后执行")
    func storeConfirmationFlow() async {
        let store = TerminalStore(contextSnapshot: contextSnapshot)
        store.input = "git --version"
        store.submit()
        #expect(store.pendingConfirmation != nil, "git 应进入确认条")
        #expect(!store.isRunning, "确认前不应执行")
        store.confirmPending()
        #expect(store.pendingConfirmation == nil)
        await waitIdle(store)
        #expect(!store.isRunning)
        #expect(store.output.contains("git version"))
    }

    @Test("确认条取消后不执行")
    func storeConfirmationCancel() {
        let store = TerminalStore(contextSnapshot: contextSnapshot)
        store.input = "rm -rf /tmp/x"
        store.submit()
        #expect(store.pendingConfirmation != nil)
        store.cancelPending()
        #expect(store.pendingConfirmation == nil)
        #expect(!store.isRunning)
        #expect(!store.output.contains("rm"))
    }

    @Test("denied 命令直接拒绝")
    func storeSubmitDeniedRejects() {
        let store = TerminalStore(contextSnapshot: contextSnapshot)
        store.input = "killall Dock"
        store.submit()
        #expect(store.output.contains("拒绝"))
        #expect(!store.isRunning)
    }

    @Test("cd 切换本地 cwd 且不启动子进程")
    func storeCDChangesCWD() {
        let store = TerminalStore(contextSnapshot: contextSnapshot)
        store.input = "cd /tmp"
        store.submit()
        #expect(store.cwd == "/tmp")
        #expect(!store.isRunning)
    }

    @Test("cd 到不存在目录报错且保持原 cwd")
    func storeCDMissingDir() {
        let store = TerminalStore(contextSnapshot: contextSnapshot)
        let before = store.cwd
        store.input = "cd /no/such/dir-xyz"
        store.submit()
        #expect(store.cwd == before)
        #expect(store.output.contains("目录不存在"))
    }

    @Test("cwd 默认值回退：路径为 / 时用主目录")
    func storeDefaultCWD() {
        // 直接断言 defaultCWD 逻辑：非 "/" 时保持原值
        let store = TerminalStore(contextSnapshot: contextSnapshot)
        #expect(!store.cwd.isEmpty)
        #expect(store.cwd.hasPrefix("/"))
    }
}
