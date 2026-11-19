import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - AJ-32 终端：命令解析 + 白名单（纯逻辑）
//
// 覆盖：① 词法切分（引号/转义/空行）
//       ② 白名单分类（allowed / confirmation / denied / unknown）
//       ③ cd 路径处理（本地切换 cwd）

@Suite("AJ-32 终端命令解析与白名单")
@MainActor
struct AJ32TerminalTests {

    // MARK: ① 词法切分

    @Test func tokenizeSimpleCommand() {
        let tokens = TerminalGuard.tokenize("ls -la")
        #expect(tokens == ["ls", "-la"])
    }

    @Test func tokenizeDoubleQuotedArgs() {
        let tokens = TerminalGuard.tokenize("echo \"hello world\"")
        #expect(tokens == ["echo", "hello world"])
    }

    @Test func tokenizeSingleQuotedArgs() {
        let tokens = TerminalGuard.tokenize("echo 'a b'")
        #expect(tokens == ["echo", "a b"])
    }

    @Test func tokenizeEscapedSpace() {
            let tokens = TerminalGuard.tokenize("echo a\\ b")
            #expect(tokens == ["echo", "a b"])
        }

    @Test func tokenizeMultipleSpaces() {
        let tokens = TerminalGuard.tokenize("ls    -la")
        #expect(tokens == ["ls", "-la"])
    }

    @Test func parseEmptyLineReturnsNil() {
        #expect(TerminalGuard.parse("") == nil)
        #expect(TerminalGuard.parse("   \n  ") == nil)
    }

    @Test func parseExtractsExecutableAndArgs() {
        let cmd = TerminalGuard.parse("git status")
        #expect(cmd?.executable == "git")
        #expect(cmd?.args == ["status"])
        #expect(cmd?.raw == "git status")
    }

    // MARK: ② 白名单分类

    @Test func allowedCommandClassifiesAsAllowed() {
        let (cmd, kind) = TerminalGuard.classify("ls -la")
        #expect(cmd?.executable == "ls")
        #expect(kind == .allowed)
    }

    @Test func readOnlyCommandsAllowed() {
        for name in ["ls", "pwd", "cat", "grep", "find", "echo", "whoami", "date", "head", "tail"] {
            #expect(TerminalGuard.classify("\(name) x").kind == .allowed, "\(name) 应为 allowed")
        }
    }

    @Test func destructiveCommandNeedsConfirmation() {
        for name in ["rm", "git", "curl", "mkdir", "cp", "mv", "swift", "brew", "chmod"] {
            #expect(TerminalGuard.classify("\(name) x").kind == .confirmation, "\(name) 应为 confirmation")
        }
    }

    @Test func deniedCommandBlocked() {
        for name in ["shutdown", "reboot", "halt", "dd", "mkfs", "mount"] {
            #expect(TerminalGuard.classify("\(name) x").kind == .denied, "\(name) 应为 denied")
        }
    }

    @Test func unknownCommandClassifiesAsUnknown() {
        #expect(TerminalGuard.classify("zzz-no-such-cmd").kind == .unknown)
    }

    @Test func classifyEmptyLineIsUnknown() {
        #expect(TerminalGuard.classify("  ").kind == .unknown)
        #expect(TerminalGuard.classify("  ").command == nil)
    }

    // MARK: ③ cd 路径处理（TerminalStore 本地切换）

    @Test func cdChangesWorkingDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aj32-cd-\(UUID().uuidString)", isDirectory: true)
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TerminalStore(contextSnapshot: TerminalContextSnapshot(
            sessionID: "session-aj32-cd",
            turnID: "turn-aj32-cd",
            taskID: "task-aj32-cd",
            projectID: "project-aj32-cd",
            workdir: root.path
        ))
        store.input = "cd \(child.path)"
        store.submit()
        #expect(store.cwd == child.path)
        #expect(store.pendingConfirmation == nil)
    }

    @Test func cdToHomeExpandsTildeButMissingScopeStaysClosed() {
        let command = TerminalGuard.parse("cd ~")
        #expect(command?.args == ["~"])
        let expanded = ("~" as NSString).expandingTildeInPath
        #expect(expanded == NSHomeDirectory())
        let noScopePolicy = TerminalPolicy(
            scopeID: "",
            allowedRoot: URL(fileURLWithPath: "/", isDirectory: true)
        )
        #expect(!noScopePolicy.allowsWorkingDirectory(expanded))

        let store = TerminalStore()
        store.cwd = "/tmp"
        store.input = "cd ~"
        store.submit()
        #expect(store.cwd == "/tmp")
        #expect(store.output.contains("路径超出允许范围"))
    }

    @Test func cdToNonExistentKeepsCwd() {
        let store = TerminalStore()
        store.cwd = "/tmp"
        store.input = "cd /definitely/not/a/real/dir/xyz"
        store.submit()
        #expect(store.cwd == "/tmp")
        #expect(store.output.contains("目录不存在"))
    }

    @Test func deniedCommandAppearsInOutputWithoutRunning() {
        let store = TerminalStore()
        store.cwd = "/tmp"
        store.input = "shutdown now"
        store.submit()
        #expect(store.pendingConfirmation == nil)
        #expect(store.output.contains("命令被拒绝"))
    }

    @Test func confirmationCommandSetsPending() {
        let store = TerminalStore()
        store.cwd = "/tmp"
        store.input = "rm -rf /tmp/x"
        store.submit()
        #expect(store.pendingConfirmation?.executable == "rm")
        #expect(store.pendingConfirmation?.args == ["-rf", "/tmp/x"])
    }

    @Test func confirmPendingRunsAndClears() {
        let store = TerminalStore(
            contextSnapshot: TerminalContextSnapshot(
                sessionID: "session-aj32-test",
                turnID: "turn-aj32-test",
                taskID: "task-aj32-test",
                projectID: "project-aj32-test",
                workdir: "/tmp"
            )
        )
        store.cwd = "/tmp"
        store.input = "echo hi"
        store.submit()
        store.pendingConfirmation = TerminalCommand(raw: "echo hi", executable: "echo", args: ["hi"])
        store.confirmPending()
        #expect(store.pendingConfirmation == nil)
    }
}
