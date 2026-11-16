import Foundation
import Testing
@testable import MinisCore

// P1-15 安全修复：allowedRoot 排除 Application Support。
// Agent 的文件工具（file_read/file_write/file_edit）不得读取应用自己的
// 敏感数据（envvars.json 中的 API key），但必须能正常读写用户工作目录。
struct ToolExecutorDeniedRootTests {

    /// 构造一个临时根目录，其中包含一个「模拟 Application Support」子目录
    /// （存放敏感 key 文件）和一个普通用户工作文件。
    private func makeFixture() -> (root: URL, denied: URL, keyFile: URL, workFile: URL) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("ToolExecutorDeniedRootTests-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("work", isDirectory: true)
        let denied = base.appendingPathComponent("Library/Application Support", isDirectory: true)
        try! fm.createDirectory(at: root, withIntermediateDirectories: true)
        try! fm.createDirectory(at: denied, withIntermediateDirectories: true)

        let keyFile = denied.appendingPathComponent("envvars.json")
        try! """
        {"OPENAI_API_KEY": {"id": "k1", "name": "OPENAI_API_KEY", "value": "sk-secret-123", "isSecret": true}}
        """.data(using: .utf8)!.write(to: keyFile)

        let workFile = root.appendingPathComponent("draft.md")
        try! "hello draft".data(using: .utf8)!.write(to: workFile)

        return (root, denied, keyFile, workFile)
    }

    @Test func fileReadRejectsDeniedRoot() async throws {
        let (root, denied, keyFile, _) = makeFixture()
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [denied])

        // 敏感文件在 deniedRoot 内、且也在 allowedRoot 内 → 必须被拒绝。
        await #expect(throws: ToolExecutorError.self) {
            _ = try await executor.execute(name: "file_read", input: ["path": keyFile.path])
        }
    }

    @Test func fileWriteRejectsDeniedRoot() async throws {
        let (root, denied, _, _) = makeFixture()
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [denied])

        let target = denied.appendingPathComponent("exfil.json")
        await #expect(throws: ToolExecutorError.self) {
            _ = try await executor.execute(name: "file_write", input: ["path": target.path, "content": "x"])
        }
    }

    @Test func fileReadAllowsUserWorkDir() async throws {
        let (root, denied, _, workFile) = makeFixture()
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [denied])

        let out = try await executor.execute(name: "file_read", input: ["path": workFile.path])
        #expect(out.contains("hello draft"))
    }

    @Test func fileWriteAllowsUserWorkDir() async throws {
        let (root, denied, _, _) = makeFixture()
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [denied])

        let target = root.appendingPathComponent("new-note.txt")
        let out = try await executor.execute(name: "file_write", input: ["path": target.path, "content": "hi"])
        #expect(out.contains("new-note.txt"))
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(try String(contentsOf: target, encoding: .utf8) == "hi")
    }

    @Test func defaultDeniedRootsCoversApplicationSupport() {
        let denied = BuiltinToolExecutor.defaultDeniedRoots()
        #expect(!denied.isEmpty)
        // 默认被拒目录应是 Application Support 根。
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let appSupport {
            #expect(denied.contains { $0.path == appSupport.path })
        }
    }
}