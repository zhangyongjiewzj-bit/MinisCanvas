import Foundation
import Testing
@testable import MinisCore

struct PhysicalAliasMutationLockBoundaryTests {
    @Test func persistentHardLinksStillRejectWriteAndEdit() async throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("hard-link-write-edit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("original.txt")
        let alias = root.appendingPathComponent("hard-link.txt")
        let original = "original synthetic bytes"
        try original.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: target, to: alias)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let operations: [(String, [String: Any])] = [
            ("file_write", ["path": target.path, "content": "replacement"]),
            ("file_edit", ["path": alias.path, "old_string": "original", "new_string": "replacement"]),
        ]
        for (name, input) in operations {
            await #expect(throws: ToolExecutorError.writeFailed("目标文件有多个硬链接，暂不支持直接修改；请另存为独立文件后重试。")) {
                try await executor.execute(name: name, input: input)
            }
            #expect(try String(contentsOf: target, encoding: .utf8) == original)
            #expect(try String(contentsOf: alias, encoding: .utf8) == original)
        }
    }
}
