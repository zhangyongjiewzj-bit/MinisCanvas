import Foundation
import Testing

@testable import MinisCore

@Suite("文件工具语义：行号、先读再改、覆盖对比、时间容忍、提交旗标（第三波 G6b）", .serialized)
struct G6bFileToolSemanticsTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("g6b-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("file_read 按 cat -n 格式给行号；max_length 只计正文")
    func readAddsLineNumbers() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt")
        try "alpha\nbeta\n".write(to: file, atomically: true, encoding: .utf8)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let whole = try await executor.execute(name: "file_read", input: ["path": file.path])
        #expect(whole == "     1\talpha\n     2\tbeta")
        let window = try await executor.execute(name: "file_read", input: ["path": file.path, "offset": 2, "lines": 1])
        #expect(window == "     2\tbeta")
    }

    @Test("覆盖已有非空文件要先读；读后被外部改动则拒绝，重读后放行")
    func overwriteRequiresReadAndDetectsExternalChange() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("b.txt")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        executor.fileChangeSessionID = "g6b-\(UUID().uuidString)"

        await #expect(throws: ToolExecutorError.self) {
            _ = try await executor.execute(name: "file_write", input: ["path": file.path, "content": "new"])
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "old")

        _ = try await executor.execute(name: "file_read", input: ["path": file.path])
        _ = try await executor.execute(name: "file_write", input: ["path": file.path, "content": "new"])
        #expect(try String(contentsOf: file, encoding: .utf8) == "new")

        try "changed by someone else".write(to: file, atomically: true, encoding: .utf8)
        await #expect(throws: ToolExecutorError.self) {
            _ = try await executor.execute(name: "file_edit",
                input: ["path": file.path, "old_string": "someone", "new_string": "me"])
        }
        _ = try await executor.execute(name: "file_read", input: ["path": file.path])
        _ = try await executor.execute(name: "file_edit",
            input: ["path": file.path, "old_string": "someone", "new_string": "me"])
        #expect(try String(contentsOf: file, encoding: .utf8) == "changed by me else")
    }

    @Test("从未读过的文件可以直接编辑（只对整体覆盖强制先读）")
    func neverReadFileCanBeEdited() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("c.txt")
        try "hello world".write(to: file, atomically: true, encoding: .utf8)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        executor.fileChangeSessionID = "g6b-\(UUID().uuidString)"
        _ = try await executor.execute(name: "file_edit",
            input: ["path": file.path, "old_string": "world", "new_string": "there"])
        #expect(try String(contentsOf: file, encoding: .utf8) == "hello there")
    }

    @Test("create_dirs 默认 true；父路径是普通文件时仍失败")
    func createDirsDefaultsToTrue() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let deep = root.appendingPathComponent("x/y/z.txt")
        _ = try await executor.execute(name: "file_write", input: ["path": deep.path, "content": "ok"])
        #expect(try String(contentsOf: deep, encoding: .utf8) == "ok")
        let blocker = root.appendingPathComponent("blocker")
        try "file".write(to: blocker, atomically: true, encoding: .utf8)
        await #expect(throws: ToolExecutorError.self) {
            _ = try await executor.execute(name: "file_write",
                input: ["path": blocker.appendingPathComponent("n.txt").path, "content": "no"])
        }
    }

    @Test("审批预览：只有时间变化且内容摘要相同仍有效；内容变化无效；删除预览保持严格")
    func previewToleratesTimeOnlyChange() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("d.txt")
        try "line one\nline two\n".write(to: file, atomically: true, encoding: .utf8)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])

        let overwrite = try await executor.prepareFileApprovalPreview(
            tool: "file_write", input: ComposerToolInput(["path": file.path, "content": "line one\nline 2\n"]))
        #expect(overwrite.text.contains("line two") && overwrite.text.contains("line 2"), "覆盖写入要给新旧对比")
        let deletion = try await executor.prepareDeletionPreview(path: file.path)

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: file.path)
        try overwrite.validateCurrent()
        #expect(throws: ApprovalFileChangedError.self) { try deletion.validateCurrent() }

        try "line one\nline TWO\n".write(to: file, atomically: false, encoding: .utf8)
        #expect(throws: ApprovalFileChangedError.self) { try overwrite.validateCurrent() }
    }

    @Test("git commit 旗标统一解析：-am、-ma、--message=、--no-verify；路径等形式标为不支持")
    func commitFlagParsing() {
        func parse(_ line: String) -> GitWorkflowPolicy.CommitInvocation? {
            GitWorkflowPolicy.parseCommit(words: TerminalGuard.inspect(line).words)
        }
        #expect(parse("git commit -am 'fix a'")?.messages == ["fix a"])
        #expect(parse("git commit -am 'fix a'")?.stageAll == true)
        // git 自己把 -ma 读成“-m a”：消息是 a，后面的词是路径，所以不是“-a 加消息”，也不受支持。
        #expect(parse("git commit -ma 'fix b'")?.messages == ["a"])
        #expect(parse("git commit -ma 'fix b'")?.supported == false)
        #expect(parse("git commit -ma 'fix b'")?.stageAll == false)
        #expect(parse("git commit --message=fix --no-verify")?.messages == ["fix"])
        #expect(parse("git commit -m x some/file.swift")?.supported == false)
        #expect(parse("git status") == nil)
    }
}
