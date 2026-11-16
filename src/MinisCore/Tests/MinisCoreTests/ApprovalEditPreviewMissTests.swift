import Foundation
import Testing
@testable import MinisCore

@Suite("R7 approval edit preview — old_string miss reason")
struct ApprovalEditPreviewMissTests {
    private func makeFile(_ body: String) throws -> (root: URL, target: URL) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("approval-edit-miss-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let target = root.appendingPathComponent("note.txt")
        try Data(body.utf8).write(to: target)
        return (root, target)
    }

    private func editFailedDetail(_ error: Error) -> String? {
        if case ToolExecutorError.editFailed(let detail) = error { return detail }
        return nil
    }

    @Test func zeroMatchReportsNotFoundWithPath() async throws {
        let (root, target) = try makeFile("alpha\nbeta\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = BuiltinToolExecutor(allowedRoot: root)
        let input = try ComposerToolInput(["path": target.path, "old_string": "THIS_STRING_DOES_NOT_EXIST_J06", "new_string": "x"])
        do {
            _ = try await owner.prepareFileApprovalPreview(tool: "file_edit", input: input)
            Issue.record("expected editFailed")
        } catch {
            let detail = try #require(editFailedDetail(error))
            #expect(detail.hasPrefix("old_string not found in "))
            #expect(detail.contains(target.path))
        }
    }

    @Test func multiMatchWithoutReplaceAllKeepsAmbiguityMessage() async throws {
        let (root, target) = try makeFile("dup\ndup\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = BuiltinToolExecutor(allowedRoot: root)
        let input = try ComposerToolInput(["path": target.path, "old_string": "dup", "new_string": "x"])
        do {
            _ = try await owner.prepareFileApprovalPreview(tool: "file_edit", input: input)
            Issue.record("expected editFailed")
        } catch {
            let detail = try #require(editFailedDetail(error))
            #expect(detail.hasPrefix("old_string must identify one location"))
        }
    }
}
