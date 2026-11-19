import Foundation
import Testing
@testable import MinisCore

@Suite("Goal18 durable file checkpoints")
struct Goal18FileCheckpointTests {
    @Test func survivesReopenAndRejectsOutsideChangesBeforeRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Goal18Checkpoint-" + UUID().uuidString).resolvingSymlinksInPath()
        try #require(root.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.txt")
        let storage = root.appendingPathComponent("checkpoints", isDirectory: true)
        let before = Data("before".utf8), after = Data("after".utf8)
        try before.write(to: file)
        let store = try FileCheckpointStore(directory: storage, allowedRoots: [root])
        let id = try store.begin(path: file, sessionID: "session", operation: .edit,
            expectedAfter: after, conversation: Data("conversation".utf8))
        try after.write(to: file)
        try store.commit(id)
        let reopened = try FileCheckpointStore(directory: storage, allowedRoots: [root])
        try Data("external".utf8).write(to: file)
        #expect(throws: FileCheckpointStore.Failure.self) { try reopened.restore(id, sessionID: "session") }
        #expect(try Data(contentsOf: file) == Data("external".utf8))
        try after.write(to: file)
        #expect(try reopened.restore(id, sessionID: "session") == Data("conversation".utf8))
        #expect(try Data(contentsOf: file) == before)
    }
    /// D-4: a store first created under the `/private/var…` spelling (fresh
    /// field/test profiles live under the per-user temporary directory) must
    /// still commit and restore after the side effect, for write and delete.
    @Test func freshPrivateSpelledStorageCommitsAndRestoresWriteAndDelete() throws {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        try #require(temporary.hasPrefix("/var/"), "requires the macOS /var symlink layout")
        let root = URL(fileURLWithPath: "/private" + temporary, isDirectory: true)
            .appendingPathComponent("Goal18Checkpoint-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Only the store keeps the `/private` spelling; executors hand the store
        // the physical target path, as in production.
        let storage = root.appendingPathComponent("file-checkpoints", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: storage.path))
        let physicalRoot = root.resolvingSymlinksInPath()
        let store = try FileCheckpointStore(directory: storage, allowedRoots: [physicalRoot])
        let file = physicalRoot.appendingPathComponent("probe.txt")
        let content = Data("hello-goal18\n".utf8)
        let writeID = try store.begin(path: file, sessionID: "session", operation: .write, expectedAfter: content)
        try content.write(to: file)
        try store.commit(writeID)
        let deleteID = try store.begin(path: file, sessionID: "session", operation: .delete, expectedAfter: nil)
        try FileManager.default.removeItem(at: file)
        try store.commit(deleteID)
        #expect(try store.summaries(sessionID: "session").map(\.id).contains(deleteID))
        _ = try store.restore(deleteID, sessionID: "session")
        #expect(try Data(contentsOf: file) == content)
    }
    @Test func symbolicCheckpointStorageIsRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Goal18Checkpoint-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("storage")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("linked-storage", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: FileCheckpointStore.Failure.self) {
            try FileCheckpointStore(directory: link, allowedRoots: [root])
        }
    }
    @Test func linkedParentWithMissingStorageIsRejectedWithoutCreatingThroughTheLink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Goal18Checkpoint-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("linked-parent", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: FileCheckpointStore.Failure.self) {
            try FileCheckpointStore(directory: link.appendingPathComponent("checkpoints", isDirectory: true),
                                    allowedRoots: [root])
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }
    @Test func expiryAndSensitiveNamesRefuseWithoutMutation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Goal18Checkpoint-" + UUID().uuidString).resolvingSymlinksInPath()
        try #require(root.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileCheckpointStore(directory: root.appendingPathComponent("checkpoints"), allowedRoots: [root])
        #expect(throws: FileCheckpointStore.Failure.self) {
            try store.begin(path: root.appendingPathComponent(".env"), sessionID: "s", operation: .write, expectedAfter: Data())
        }
        let date = Date(timeIntervalSince1970: 1_000_000)
        let path = root.appendingPathComponent("new.txt")
        let id = try store.begin(path: path, sessionID: "s", operation: .write, expectedAfter: Data("new".utf8), now: date)
        try Data("new".utf8).write(to: path)
        try store.commit(id, now: date)
        for days in [30, 31] {
            do {
                _ = try store.restore(id, sessionID: "s", now: date.addingTimeInterval(Double(days * 86400)))
                Issue.record("A committed checkpoint must expire at the retention boundary")
            } catch FileCheckpointStore.Failure.expired {
                // Only expiry satisfies this boundary, not an uncommitted record.
            } catch {
                Issue.record("Expired restore returned a different failure category")
            }
            #expect(try Data(contentsOf: path) == Data("new".utf8))
        }
        #expect(try Data(contentsOf: path) == Data("new".utf8))

        let validPath = root.appendingPathComponent("valid-at-29.txt")
        let before = Data("before".utf8), after = Data("after".utf8)
        try before.write(to: validPath)
        let validID = try store.begin(path: validPath, sessionID: "s", operation: .edit,
            expectedAfter: after, now: date)
        try after.write(to: validPath)
        try store.commit(validID, now: date)
        _ = try store.restore(validID, sessionID: "s", now: date.addingTimeInterval(29 * 86400))
        #expect(try Data(contentsOf: validPath) == before)

        let recordFile = root.appendingPathComponent("checkpoints").appendingPathComponent(id.uuidString + ".json")
        #expect(FileManager.default.fileExists(atPath: recordFile.path))
        try store.prune(now: date.addingTimeInterval(29 * 86400))
        #expect(FileManager.default.fileExists(atPath: recordFile.path))
        try store.prune(now: date.addingTimeInterval(31 * 86400))
        #expect(!FileManager.default.fileExists(atPath: recordFile.path))
        #expect(try Data(contentsOf: path) == Data("new".utf8))
    }
    @Test func memoryBudgetAndReceiptAgree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Goal18Memory-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore(directory: root)
        let scope = MemoryScope(sessionID: "s", projectID: "p")
        _ = try store.addFact("晴天第一条", memoryScope: scope)
        _ = try store.addFact("晴天第二条", memoryScope: scope)
        let injector = MemoryInjector(store: store, maxFacts: 10, maxFactLength: 200, maxTotalCharacters: MemoryInjector.promptHeader.count + 9 + MemoryInjector.dateSuffixLength)
        let result = try injector.injection(base: "", userMessage: "晴天", context: MemoryInjectionContext(scope: scope))
        #expect(result.injectedFactIDs.count == 1)
        #expect(result.prompt.count <= injector.maxTotalCharacters)
        #expect(result.prompt.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count == 1)
    }
    @Test func checkpointFailurePreventsRealBuiltinWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Goal18Checkpoint-" + UUID().uuidString).resolvingSymlinksInPath()
        try #require(root.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.txt")
        try Data("original".utf8).write(to: file)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        executor.fileCheckpointsEnabled = true
        executor.fileChangeSessionID = "s"
        executor.markFileRead(path: file.path) // 覆盖已有文件要求先读；这里要验证的是检查点失败而不是未读
        await #expect(throws: (any Error).self) {
            try await executor.execute(name: "file_write", input: ["path": file.path, "content": "changed"])
        }
        #expect(try Data(contentsOf: file) == Data("original".utf8))
    }
    @Test func checkpointSizeBoundaryNeverTruncatesBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Goal18Checkpoint-" + UUID().uuidString).resolvingSymlinksInPath()
        try #require(root.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileCheckpointStore(directory: root.appendingPathComponent("checkpoints"), allowedRoots: [root])
        let path = root.appendingPathComponent("sample.txt")
        try Data("original".utf8).write(to: path)
        let exact = Data(repeating: 65, count: 16 * 1024 * 1024)
        let id = try store.begin(path: path, sessionID: "s", operation: .write, expectedAfter: exact)
        #expect(!id.uuidString.isEmpty)
        #expect(throws: FileCheckpointStore.Failure.self) {
            try store.begin(path: path, sessionID: "s", operation: .write, expectedAfter: exact + Data([65]))
        }
        #expect(try Data(contentsOf: path) == Data("original".utf8))
    }

    @Test func childProducerIdentityStaysDistinctAndOnlyVerifiedParentCanRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Goal18Checkpoint-" + UUID().uuidString).resolvingSymlinksInPath()
        try #require(root.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("checkpoints")
        let path = root.appendingPathComponent("sample.txt")
        try Data("before".utf8).write(to: path)
        let store = try FileCheckpointStore(directory: storage, allowedRoots: [root])
        let id = try store.begin(path: path, sessionID: "child", operation: .edit,
            expectedAfter: Data("after".utf8), conversation: Data("parent-snapshot".utf8), parentSessionID: "parent")
        try Data("after".utf8).write(to: path)
        try store.commit(id)
        let reopened = try FileCheckpointStore(directory: storage, allowedRoots: [root])
        let summary = try #require(reopened.summaries(sessionID: "parent").first)
        #expect(summary.producerSessionID == "child")
        #expect(summary.hasConversation)
        #expect(try reopened.summaries(sessionID: "sibling").isEmpty)
        #expect(throws: FileCheckpointStore.Failure.self) { try reopened.restore(id, sessionID: "sibling") }
        #expect(try Data(contentsOf: path) == Data("after".utf8))
        #expect(try reopened.restore(id, sessionID: "parent") == Data("parent-snapshot".utf8))
        #expect(try Data(contentsOf: path) == Data("before".utf8))
    }

}
