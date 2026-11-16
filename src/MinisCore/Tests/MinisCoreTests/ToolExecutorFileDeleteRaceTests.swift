import Foundation
import Testing
@testable import MinisCore

@Suite("file_delete anchored unlink race refusals")
struct ToolExecutorFileDeleteRaceTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-delete-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func executor(_ root: URL, ledgerRoot: URL? = nil) -> BuiltinToolExecutor {
        let value = BuiltinToolExecutor(allowedRoot: root)
        value.fileChangeLedger = FileChangeLedger(workspaceRoot: (ledgerRoot ?? root).path)
        value.fileChangeSessionID = "synthetic-delete-session"
        return value
    }

    @Test("delete preview cannot borrow the owner's wider root across a child write boundary")
    func previewRetainsChildWriteScope() async throws {
        let root = try fixture().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let target = root.appendingPathComponent("parent-only.txt")
        try Data("parent-only synthetic text\n".utf8).write(to: target)
        let owner = executor(root)
        // The same owner accepts the target without the narrower child scope.
        #expect(try await owner.prepareDeletionPreview(path: target.path).deletionContentDigest != nil)
        let narrow = ChildToolWorkspaceScope(readRoots: [root.path], writeRoots: [child.path],
            workingDirectory: child.path, deniedRoots: [], parentAuthorityCheck: nil)
        await ChildToolWorkspaceScope.$current.withValue(narrow) {
            await #expect(throws: ToolExecutorError.pathViolation(target.path)) {
                _ = try await owner.prepareDeletionPreview(path: target.path)
            }
        }
    }

    @Test("ordinary deletion preview shows path size and exactly three lines with a full content hash")
    func ordinaryPreviewBindsEntireFile() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("preview.txt")
        let data = Data("one\ntwo\nthree\nfour\n".utf8)
        try data.write(to: target)
        let preview = try await executor(root).prepareDeletionPreview(path: target.path)
        #expect(preview.text.contains(target.path))
        #expect(preview.text.contains("\(data.count) bytes"))
        #expect(preview.text.contains("one\ntwo\nthree"))
        #expect(!preview.text.contains("four"))
        #expect(preview.deletionContentDigest == ApprovalFilePreview.digest(data))
        #expect(preview.deletionContentDigest != ApprovalFilePreview.digest(Data("one\ntwo\nthree\nchanged\n".utf8)))
    }

    @Test("multiline secret is redacted before selecting the visible three lines")
    func multilineSecretCannotEscapeAtThirdLine() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("preview.txt")
        let canary = String(repeating: "SyntheticCanary", count: 8)
        let content = "heading\n-----BEGIN PRIVATE KEY-----\n" + canary + "\n-----END PRIVATE KEY-----\n"
        try Data(content.utf8).write(to: target)
        let preview = try await executor(root).prepareDeletionPreview(path: target.path)
        #expect(!preview.text.contains(canary))
        #expect(preview.deletionContentDigest == ApprovalFilePreview.digest(Data(content.utf8)))
    }

    @Test("changing text after the visible three lines cannot use the old delete approval")
    func invisibleTailMutationRefusesDeletion() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("preview.txt")
        try Data("one\ntwo\nthree\ntail-A\n".utf8).write(to: target)
        let owner = executor(root)
        let preview = try await owner.prepareDeletionPreview(path: target.path)
        try Data("one\ntwo\nthree\ntail-B\n".utf8).write(to: target)
        await #expect(throws: ApprovalFileChangedError.self) {
            try await ApprovalFilePreviewContext.$current.withValue(preview) {
                _ = try await owner.execute(name: "file_delete", input: ["path": target.path])
            }
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "one\ntwo\nthree\ntail-B\n")
    }

    @Test("canonical parent replacement refuses anchored deletion and leaves both files")
    func parentReplacementCannotChangeLedgerPath() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let parked = root.appendingPathComponent("parked", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let target = parent.appendingPathComponent("victim.txt")
        try "old synthetic bytes\n".write(to: target, atomically: true, encoding: .utf8)
        let executor = executor(root)
        await #expect(throws: ToolExecutorError.pathViolation(target.path)) {
            try await FileDeleteRaceFixture.$beforeFinalCheck.withValue({
                try! FileManager.default.moveItem(at: parent, to: parked)
                try! FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
                try! "replacement stays\n".write(
                    to: target, atomically: true, encoding: .utf8
                )
            }) {
                _ = try await executor.execute(name: "file_delete", input: ["path": target.path])
            }
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "replacement stays\n")
        #expect(try String(contentsOf: parked.appendingPathComponent("victim.txt"),
                           encoding: .utf8) == "old synthetic bytes\n")
    }

    @Test("same-directory regular substitution is restored without deleting either file")
    func regularReplacementAfterFinalCheckIsRestored() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("victim.txt")
        let parked = root.appendingPathComponent("parked.txt")
        let substitute = root.appendingPathComponent("substitute.txt")
        try "approved old bytes\n".write(to: target, atomically: true, encoding: .utf8)
        try "different replacement\n".write(to: substitute, atomically: true, encoding: .utf8)
        let executor = executor(root)
        await #expect(throws: ToolExecutorError.invalidParameter("file changed before deletion")) {
            try await FileDeleteRaceFixture.$beforeQuarantineMove.withValue({
                try! FileManager.default.moveItem(at: target, to: parked)
                try! FileManager.default.moveItem(at: substitute, to: target)
            }) {
                _ = try await executor.execute(name: "file_delete", input: ["path": target.path])
            }
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "different replacement\n")
        #expect(try String(contentsOf: parked, encoding: .utf8) == "approved old bytes\n")
        let entries = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil)
        #expect(!entries.contains { $0.lastPathComponent.hasPrefix(".minis-delete-") })
    }

    @Test("directory substituted after check remains intact")
    func directoryReplacementCannotRecurse() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("victim.txt")
        let parked = root.appendingPathComponent("parked.txt")
        try "synthetic old bytes\n".write(to: target, atomically: true, encoding: .utf8)
        let executor = executor(root)
        await #expect(throws: ToolExecutorError.invalidParameter("file changed before deletion")) {
            try await FileDeleteRaceFixture.$beforeFinalCheck.withValue({
                try! FileManager.default.moveItem(at: target, to: parked)
                try! FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                try! "nested stays\n".write(
                    to: target.appendingPathComponent("nested.txt"), atomically: true, encoding: .utf8
                )
            }) {
                _ = try await executor.execute(
                    name: "file_delete", input: ["path": target.path]
                )
            }
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(try String(contentsOf: target.appendingPathComponent("nested.txt"), encoding: .utf8) == "nested stays\n")
        #expect(try String(contentsOf: parked, encoding: .utf8) == "synthetic old bytes\n")
    }

    @Test("outside symlink substituted after check cannot touch its target")
    func outsideSymlinkReplacementCannotEscape() async throws {
        let root = try fixture()
        let outsideRoot = try fixture()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outsideRoot)
        }
        let target = root.appendingPathComponent("victim.txt")
        let parked = root.appendingPathComponent("parked.txt")
        let outside = outsideRoot.appendingPathComponent("outside.txt")
        try "synthetic old bytes\n".write(to: target, atomically: true, encoding: .utf8)
        try "outside stays\n".write(to: outside, atomically: true, encoding: .utf8)
        let executor = executor(root)
        await #expect(throws: ToolExecutorError.invalidParameter("file changed before deletion")) {
            try await FileDeleteRaceFixture.$beforeFinalCheck.withValue({
                try! FileManager.default.moveItem(at: target, to: parked)
                try! FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
            }) {
                _ = try await executor.execute(
                    name: "file_delete", input: ["path": target.path]
                )
            }
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside stays\n")
        #expect(try String(contentsOf: parked, encoding: .utf8) == "synthetic old bytes\n")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil)
    }

    @Test("oversize UTF-8 file is refused without moving or recording")
    func oversizeFileRefused() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("large.txt")
        let bytes = Data(repeating: 65, count: 64 * 1024 + 1)
        try bytes.write(to: target)
        let tool = executor(root)
        await #expect(throws: ToolExecutorError.invalidParameter(
            "path must name the same regular text file of at most 64 KiB"
        )) {
            _ = try await tool.execute(name: "file_delete", input: ["path": target.path])
        }
        #expect(try Data(contentsOf: target) == bytes)
        #expect(tool.fileChangeLedger?.count == 0)
    }

    @Test("NUL text and invalid UTF-8 are each refused without a deletion record")
    func binaryContentsRefused() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = executor(root)
        for (name, bytes) in [("nul.txt", Data([65, 0, 66])),
                              ("invalid.txt", Data([0xFF, 0xFE]))] {
            let target = root.appendingPathComponent(name)
            try bytes.write(to: target)
            await #expect(throws: ToolExecutorError.fileIsBinary(target.path)) {
                _ = try await tool.execute(name: "file_delete", input: ["path": target.path])
            }
            #expect(try Data(contentsOf: target) == bytes)
        }
        #expect(tool.fileChangeLedger?.count == 0)
    }

    @Test("hard-linked file is refused with both names intact")
    func hardLinkRefused() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("linked.txt")
        let other = root.appendingPathComponent("other.txt")
        try "synthetic linked bytes".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: target, to: other)
        let tool = executor(root)
        await #expect(throws: ToolExecutorError.writeFailed(
            "目标文件有多个硬链接，暂不支持直接修改；请另存为独立文件后重试。"
        )) {
            _ = try await tool.execute(name: "file_delete", input: ["path": target.path])
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "synthetic linked bytes")
        #expect(try String(contentsOf: other, encoding: .utf8) == "synthetic linked bytes")
        #expect(tool.fileChangeLedger?.count == 0)
    }

    @Test("registration failure restores the quarantined file before returning error")
    func ledgerFailureRestoresFile() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("victim.txt")
        try "synthetic content".write(to: target, atomically: true, encoding: .utf8)
        let tool = executor(root, ledgerRoot: root.appendingPathComponent("other-ledger-root"))
        await #expect(throws: (any Error).self) {
            _ = try await tool.execute(name: "file_delete", input: ["path": target.path])
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "synthetic content")
        #expect(tool.fileChangeLedger?.count == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy {
            !$0.hasPrefix(".minis-delete-")
        })
    }

    @Test("missing ledger or session refuses deletion before quarantine")
    func missingLedgerOrSessionRefused() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("victim.txt")
        try "synthetic content".write(to: target, atomically: true, encoding: .utf8)
        let missingLedger = BuiltinToolExecutor(allowedRoot: root)
        missingLedger.fileChangeSessionID = "synthetic-delete-session"
        await #expect(throws: ToolExecutorError.writeFailed(
            "File change ledger unavailable for deletion"
        )) {
            _ = try await missingLedger.execute(name: "file_delete", input: ["path": target.path])
        }
        let missingSession = BuiltinToolExecutor(allowedRoot: root)
        missingSession.fileChangeLedger = FileChangeLedger(workspaceRoot: root.path)
        await #expect(throws: ToolExecutorError.writeFailed(
            "File change session unavailable for deletion"
        )) {
            _ = try await missingSession.execute(name: "file_delete", input: ["path": target.path])
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "synthetic content")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["victim.txt"])
    }

    @Test("unlink failure restores file and rolls back the pre-delete ledger entry")
    func unlinkFailureRollsBackRegistration() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("victim.txt")
        try "synthetic content".write(to: target, atomically: true, encoding: .utf8)
        let tool = executor(root)
        let ledger = try #require(tool.fileChangeLedger)
        await #expect(throws: ToolExecutorError.permissionDenied(target.path)) {
            try await FileDeleteRaceFixture.$beforePhysicalUnlink.withValue({
                #expect(ledger.count == 1)
                return EACCES
            }) {
                _ = try await tool.execute(name: "file_delete", input: ["path": target.path])
            }
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "synthetic content")
        #expect(tool.fileChangeLedger?.count == 0)
    }

    @Test("directory substituted inside quarantine after rename is restored intact")
    func postRenameDirectoryCannotBeDeleted() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("victim.txt")
        let parked = root.appendingPathComponent("parked.txt")
        try "approved bytes".write(to: target, atomically: true, encoding: .utf8)
        let tool = executor(root)
        await #expect(throws: ToolExecutorError.invalidParameter("file changed before deletion")) {
            try await FileDeleteRaceFixture.$afterQuarantineMove.withValue({ moved in
                try! FileManager.default.moveItem(at: moved, to: parked)
                try! FileManager.default.createDirectory(at: moved, withIntermediateDirectories: false)
                try! "nested stays".write(to: moved.appendingPathComponent("nested.txt"),
                                           atomically: true, encoding: .utf8)
            }) {
                _ = try await tool.execute(name: "file_delete", input: ["path": target.path])
            }
        }
        #expect(try String(contentsOf: parked, encoding: .utf8) == "approved bytes")
        #expect(try String(contentsOf: target.appendingPathComponent("nested.txt"), encoding: .utf8)
                == "nested stays")
        #expect(tool.fileChangeLedger?.count == 0)
    }

    @Test("outside symlink substituted inside quarantine cannot touch outside bytes")
    func postRenameSymlinkCannotEscape() async throws {
        let root = try fixture()
        let outsideRoot = try fixture()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outsideRoot)
        }
        let target = root.appendingPathComponent("victim.txt")
        let parked = root.appendingPathComponent("parked.txt")
        let outside = outsideRoot.appendingPathComponent("outside.txt")
        try "approved bytes".write(to: target, atomically: true, encoding: .utf8)
        try "outside stays".write(to: outside, atomically: true, encoding: .utf8)
        let tool = executor(root)
        await #expect(throws: ToolExecutorError.invalidParameter("file changed before deletion")) {
            try await FileDeleteRaceFixture.$afterQuarantineMove.withValue({ moved in
                try! FileManager.default.moveItem(at: moved, to: parked)
                try! FileManager.default.createSymbolicLink(at: moved, withDestinationURL: outside)
            }) {
                _ = try await tool.execute(name: "file_delete", input: ["path": target.path])
            }
        }
        #expect(try String(contentsOf: parked, encoding: .utf8) == "approved bytes")
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside stays")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil)
        #expect(tool.fileChangeLedger?.count == 0)
    }
}
