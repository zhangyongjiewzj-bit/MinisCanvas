import Foundation
import Testing
@testable import MinisCore

@Suite("D-PRIVACY-01 file tools stay inside configured roots")
struct P3AcceptanceM07FileAllowedRootsTests {
    @Test func outsideConfiguredRootsRejectsWriteAndEditWithoutMutation() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(
            "M07-FileAllowedRoots-\(UUID().uuidString)", isDirectory: true
        )
        let configuredRoot = base.appendingPathComponent("workspace", isDirectory: true)
        let mountedRoot = base.appendingPathComponent("mounted", isDirectory: true)
        // A sibling with the same prefix must never count as a descendant.
        let outside = base.appendingPathComponent("workspace-copy", isDirectory: true)
        try fm.createDirectory(at: configuredRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: mountedRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)

        let existing = outside.appendingPathComponent("existing.txt")
        try "unchanged".write(to: existing, atomically: true, encoding: .utf8)
        let newFile = outside.appendingPathComponent("nested/new.txt")
        let executor = BuiltinToolExecutor(
            allowedRoot: configuredRoot,
            deniedRoots: [],
            additionalAllowedRoots: [mountedRoot]
        )

        await #expect(throws: ToolExecutorError.pathViolation(newFile.path)) {
            _ = try await executor.execute(
                name: "file_write",
                input: ["path": newFile.path, "content": "blocked", "create_dirs": true]
            )
        }
        #expect(!fm.fileExists(atPath: newFile.path))
        #expect(!fm.fileExists(atPath: newFile.deletingLastPathComponent().path))

        await #expect(throws: ToolExecutorError.pathViolation(existing.path)) {
            _ = try await executor.execute(
                name: "file_edit",
                input: ["path": existing.path, "old_string": "unchanged", "new_string": "changed"]
            )
        }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "unchanged")
    }
}
