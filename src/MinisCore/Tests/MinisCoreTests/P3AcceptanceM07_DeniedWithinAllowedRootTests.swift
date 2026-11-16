import Foundation
import Testing
@testable import MinisCore

@Suite("D-PRIVACY-02 deny rule overrides an allowed file root")
struct P3AcceptanceM07DeniedWithinAllowedRootTests {
    @Test func directlyNestedDenyBlocksAllFileToolsWithoutMutation() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(
            "M07-DeniedWithinAllowed-\(UUID().uuidString)", isDirectory: true
        )
        let allowed = base.appendingPathComponent("workspace", isDirectory: true)
        let denied = allowed.appendingPathComponent("excluded", isDirectory: true)
        try fm.createDirectory(at: denied, withIntermediateDirectories: true)

        let excludedFile = denied.appendingPathComponent("document.txt")
        try "unchanged".write(to: excludedFile, atomically: true, encoding: .utf8)
        let normalFile = allowed.appendingPathComponent("normal.txt")
        try "allowed".write(to: normalFile, atomically: true, encoding: .utf8)
        let newFile = denied.appendingPathComponent("nested/new.txt")
        let executor = BuiltinToolExecutor(allowedRoot: allowed, deniedRoots: [denied])

        let normalRead = try await executor.execute(
            name: "file_read", input: ["path": normalFile.path]
        )
        #expect(normalRead == "allowed")
        await #expect(throws: ToolExecutorError.pathViolation(excludedFile.path)) {
            _ = try await executor.execute(name: "file_read", input: ["path": excludedFile.path])
        }
        await #expect(throws: ToolExecutorError.pathViolation(newFile.path)) {
            _ = try await executor.execute(
                name: "file_write",
                input: ["path": newFile.path, "content": "blocked", "create_dirs": true]
            )
        }
        #expect(!fm.fileExists(atPath: newFile.path))
        #expect(!fm.fileExists(atPath: newFile.deletingLastPathComponent().path))
        await #expect(throws: ToolExecutorError.pathViolation(excludedFile.path)) {
            _ = try await executor.execute(
                name: "file_edit",
                input: ["path": excludedFile.path, "old_string": "unchanged", "new_string": "changed"]
            )
        }
        #expect(try String(contentsOf: excludedFile, encoding: .utf8) == "unchanged")
    }
}
