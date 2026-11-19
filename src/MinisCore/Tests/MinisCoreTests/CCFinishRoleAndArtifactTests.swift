import Foundation
import Testing
@testable import MinisCore

struct CCFinishRoleAndArtifactTests {
    @Test func rolePresetsAreDistinctAndDoNotGrantCapabilities() throws {
        #expect(ChildRolePreset.allCases == [.research, .review])
        #expect(ChildRolePreset.research.instructionPrefix.contains("研究角色"))
        #expect(ChildRolePreset.review.instructionPrefix.contains("评审角色"))
        for role in ChildRolePreset.allCases {
            #expect(role.instructionPrefix.contains("不授予额外工具、目录或写入权限"))
            #expect(try JSONDecoder().decode(ChildRolePreset.self,
                from: JSONEncoder().encode(role)) == role)
        }
        #expect(ChildRolePreset(rawValue: "administrator") == nil)
    }

    @Test func thresholdKeepsInlineAndDoesNotCreateDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ToolOutputArtifactStore(sessionStorageRoot: root, sessionID: UUID())
        #expect(try store.persistIfLarge(redactedOutput: String(repeating: "字", count: 30_000)) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func unicodeOutputIsCompleteWhilePreviewKeepsBothEnds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = "HEAD\n" + String(repeating: "测👩🏽‍💻", count: 16_000) + "\nTAIL"
        let store = ToolOutputArtifactStore(sessionStorageRoot: root, sessionID: UUID())
        let artifact = try #require(try store.persistIfLarge(redactedOutput: output))
        #expect(try String(contentsOf: artifact.fileURL, encoding: .utf8) == output)
        #expect(artifact.characterCount == output.count)
        #expect(artifact.byteCount == output.utf8.count)
        #expect(artifact.preview.hasPrefix("HEAD\n"))
        #expect(artifact.preview.hasSuffix("\nTAIL"))
        #expect(artifact.preview.count < 3_100)
        #expect(artifact.referenceText.contains(artifact.fileURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: artifact.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((attributes[.size] as? NSNumber)?.intValue == artifact.byteCount)
        let second = try #require(try store.persistIfLarge(redactedOutput: output))
        #expect(second.fileURL != artifact.fileURL)
    }

    @Test func failedWriteDoesNotReturnAnArtifactReference() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("parent is a file".utf8).write(to: root)
        let store = ToolOutputArtifactStore(sessionStorageRoot: root.appendingPathComponent("child"), sessionID: UUID())
        #expect(throws: (any Error).self) {
            try store.persistIfLarge(redactedOutput: String(repeating: "x", count: 30_001))
        }
    }

    @Test func sessionDeletionRemovesOnlyItsOwnOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ToolOutputArtifactStore(sessionStorageRoot: root, sessionID: UUID())
        let second = ToolOutputArtifactStore(sessionStorageRoot: root, sessionID: UUID())
        let output = String(repeating: "x", count: 30_001)
        let deleted = try #require(try first.persistIfLarge(redactedOutput: output))
        let retained = try #require(try second.persistIfLarge(redactedOutput: output))
        try first.removeSessionArtifacts()
        #expect(!FileManager.default.fileExists(atPath: deleted.fileURL.path))
        #expect(try String(contentsOf: retained.fileURL, encoding: .utf8) == output)
        #expect(deleted.fileURL.path.hasPrefix(root.resolvingSymlinksInPath().path + "/tool-output/"))
    }

    @Test func redirectedSessionDirectoryCannotDeleteAnotherSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ToolOutputArtifactStore(sessionStorageRoot: root, sessionID: UUID())
        let second = ToolOutputArtifactStore(sessionStorageRoot: root, sessionID: UUID())
        let retained = try #require(try second.persistIfLarge(redactedOutput: String(repeating: "x", count: 30_001)))
        let link = ToolOutputArtifactStore.directory(sessionStorageRoot: root, sessionID: first.sessionID)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: retained.fileURL.deletingLastPathComponent())
        #expect(throws: ToolExecutorError.self) { try first.removeSessionArtifacts() }
        #expect(try first.resolveArtifactPath(root.appendingPathComponent("ordinary.txt").path) == nil)
        #expect(FileManager.default.fileExists(atPath: retained.fileURL.path))
    }


    @Test func onlyCurrentSessionProducedArtifactHasAReadReceipt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ToolOutputArtifactStore(sessionStorageRoot: root, sessionID: UUID())
        let second = ToolOutputArtifactStore(sessionStorageRoot: root, sessionID: UUID())
        let output = try #require(try first.persistIfLarge(redactedOutput: String(repeating: "x", count: 30_001)))
        #expect(try first.resolveArtifactPath(output.fileURL.path) == output.fileURL)
        #expect(throws: ToolExecutorError.self) { try second.resolveArtifactPath(output.fileURL.path) }
        let unregistered = output.fileURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".txt")
        try Data("not produced".utf8).write(to: unregistered)
        #expect(throws: ToolExecutorError.self) { try first.resolveArtifactPath(unregistered.path) }
        #expect(try first.resolveArtifactPath(root.appendingPathComponent("sessions/private.json").path) == nil)
        try FileManager.default.removeItem(at: output.fileURL)
        #expect(throws: ToolExecutorError.fileNotFound(output.fileURL.path)) {
            try first.resolveArtifactPath(output.fileURL.path)
        }
        try first.removeSessionArtifacts()
        #expect(throws: ToolExecutorError.self) { try first.resolveArtifactPath(output.fileURL.path) }
    }

    @Test func producedReceiptDoesNotAuthorizeSymlinkOrReplacedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ToolOutputArtifactStore(sessionStorageRoot: root, sessionID: UUID())
        let output = try #require(try store.persistIfLarge(redactedOutput: String(repeating: "x", count: 30_001)))
        let foreign = root.appendingPathComponent("foreign.txt")
        try Data("foreign".utf8).write(to: foreign)
        try FileManager.default.removeItem(at: output.fileURL)
        try FileManager.default.createSymbolicLink(at: output.fileURL, withDestinationURL: foreign)
        #expect(throws: ToolExecutorError.self) { try store.resolveArtifactPath(output.fileURL.path) }
        try FileManager.default.removeItem(at: output.fileURL)
        try Data("replacement".utf8).write(to: output.fileURL)
        #expect(throws: ToolExecutorError.self) { try store.resolveArtifactPath(output.fileURL.path) }
    }


    @Test func sharedReadResolverNeedsTheTrustedCurrentSessionScope() throws {
        let base = try FormalTestIsolationPaths.resolveCurrentProcess()?.rootDirectory
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let store = ToolOutputArtifactStore(sessionStorageRoot: root, sessionID: id)
        let output = try #require(try store.persistIfLarge(redactedOutput: String(repeating: "x", count: 30_001)))
        #expect(try ToolOutputArtifactStore.resolveOwnedArtifact(path: output.fileURL.path) == nil)
        try ToolOutputArtifactSessionScope.$current.withValue(
            ToolOutputArtifactSessionScope(sessionStorageRoot: root, sessionID: id)) {
            let resolvedArtifact = try ToolOutputArtifactStore.resolveOwnedArtifact(path: output.fileURL.path)
            #expect(resolvedArtifact == output.fileURL)
            let artifactData = try ToolOutputArtifactStore.readOwnedArtifact(path: output.fileURL.path)
            #expect(artifactData == Data(String(repeating: "x", count: 30_001).utf8))
        }
        ToolOutputArtifactSessionScope.$current.withValue(
            ToolOutputArtifactSessionScope(sessionStorageRoot: root, sessionID: UUID())) {
            #expect(throws: ToolExecutorError.self) {
                try ToolOutputArtifactStore.resolveOwnedArtifact(path: output.fileURL.path)
            }
        }
    }

    @Test func savedMCPImageCanBeReadByItsOwnSessionOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ToolOutputArtifactStore(sessionStorageRoot: root, sessionID: UUID())
        let second = ToolOutputArtifactStore(sessionStorageRoot: root, sessionID: UUID())
        let imageURL = try first.persistImage(Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]), fileExtension: "png")
        #expect(try first.resolveArtifactPath(imageURL.path) == imageURL)
        #expect(throws: ToolExecutorError.self) { try second.resolveArtifactPath(imageURL.path) }
        // 清单随图片一起写入会话输出目录（重启后凭内容哈希恢复读取资格）。
        let manifest = imageURL.deletingLastPathComponent().appendingPathComponent("manifest.json")
        #expect(FileManager.default.fileExists(atPath: manifest.path))
    }

    @Test func sessionOutputDirectoryOverQuotaDropsOldestFilesFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ToolOutputArtifactStore(sessionStorageRoot: root, sessionID: UUID())
        let bytes = Data(repeating: 7, count: 100)
        let oldest = try store.persistImage(bytes, fileExtension: "png")
        let middle = try store.persistImage(bytes, fileExtension: "png")
        let newest = try store.persistImage(bytes, fileExtension: "png")
        let directory = oldest.deletingLastPathComponent()
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30)], ofItemAtPath: oldest.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-20)], ofItemAtPath: middle.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-10)], ofItemAtPath: newest.path)

        // 上限 250 字节：三张 100 字节的图要删掉最旧的一张；刚写入的文件始终保留。
        ToolOutputArtifactStore.enforceSessionQuota(
            directory: directory, keeping: newest.lastPathComponent, limit: 250)
        #expect(!FileManager.default.fileExists(atPath: oldest.path))
        #expect(FileManager.default.fileExists(atPath: middle.path))
        #expect(FileManager.default.fileExists(atPath: newest.path))
        // 被清理的文件不能再按路径读取。
        #expect(throws: ToolExecutorError.self) { try store.resolveArtifactPath(oldest.path) }
        #expect(try store.resolveArtifactPath(newest.path) == newest)
    }

}
