import Foundation
import Testing
@testable import MinisCore

@Suite("检查点：恢复到此之前、对话快照降级、敏感判据")
struct FileCheckpointRewindTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CheckpointRewind-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func change(_ store: FileCheckpointStore, _ file: URL, to text: String, at date: Date,
                        operation: FileCheckpointStore.Operation = .edit) throws {
        let data = Data(text.utf8)
        let id = try store.begin(path: file, sessionID: "s", operation: operation, expectedAfter: data, now: date)
        try data.write(to: file)
        try store.commit(id, now: date)
    }

    @Test func rewindBeforeCheckpointRestoresNewestFirstAcrossFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        try Data("a0".utf8).write(to: a); try Data("b0".utf8).write(to: b)
        let store = try FileCheckpointStore(directory: root.appendingPathComponent("cp"), allowedRoots: [root])
        let t0 = Date().addingTimeInterval(-100)
        try change(store, a, to: "a1", at: t0)
        try change(store, b, to: "b1", at: t0.addingTimeInterval(10))
        try change(store, a, to: "a2", at: t0.addingTimeInterval(20))
        let first = try #require(store.summaries(sessionID: "s").last)
        let plan = try store.rewindPlan(before: first.id, sessionID: "s")
        #expect(plan.summaries.count == 3)
        _ = try store.restoreBefore(plan, sessionID: "s") { _ in true }
        #expect(try String(contentsOf: a, encoding: .utf8) == "a0")
        #expect(try String(contentsOf: b, encoding: .utf8) == "b0")
    }

    @Test func rewindChangesNothingWhenOnePathFailsPreflight() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        try Data("a0".utf8).write(to: a); try Data("b0".utf8).write(to: b)
        let store = try FileCheckpointStore(directory: root.appendingPathComponent("cp"), allowedRoots: [root])
        let t0 = Date().addingTimeInterval(-100)
        try change(store, a, to: "a1", at: t0)
        try change(store, b, to: "b1", at: t0.addingTimeInterval(10))
        try Data("b-external".utf8).write(to: b)
        let plan = try store.rewindPlan(before: try #require(store.summaries(sessionID: "s").last).id, sessionID: "s")
        do {
            _ = try store.restoreBefore(plan, sessionID: "s") { _ in true }
            Issue.record("expected conflict")
        } catch let error as FileCheckpointStore.RewindConflictError {
            #expect(error.items.map(\.path) == [b.path])
            #expect(error.items.first?.reason == .changed)
        }
        #expect(try String(contentsOf: a, encoding: .utf8) == "a1")
        #expect(throws: FileCheckpointStore.Failure.notAuthorized) {
            try store.restoreBefore(plan, sessionID: "s") { $0 != b.path }
        }
        try FileManager.default.removeItem(at: b)
        #expect(throws: FileCheckpointStore.RewindConflictError.self) {
            try store.restoreBefore(plan, sessionID: "s") { _ in true }
        }
    }

    @Test func plainRewindRollsBackRestoredFilesWhenALaterWriteFails() throws {
        let root = try makeRoot()
        let locked = root.appendingPathComponent("locked")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let a = locked.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        try Data("a0".utf8).write(to: a); try Data("b0".utf8).write(to: b)
        let store = try FileCheckpointStore(directory: root.appendingPathComponent("cp"), allowedRoots: [root])
        let t0 = Date().addingTimeInterval(-100)
        try change(store, a, to: "a1", at: t0)
        try change(store, b, to: "b1", at: t0.addingTimeInterval(10))
        let plan = try store.rewindPlan(before: try #require(store.summaries(sessionID: "s").last).id, sessionID: "s")
        // 先恢复较新的 b，再恢复 a 时因目录不可写失败。
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        #expect(throws: (any Error).self) {
            try store.restoreBefore(plan, sessionID: "s") { _ in true }
        }
        #expect(try String(contentsOf: b, encoding: .utf8) == "b1")
        #expect(try String(contentsOf: a, encoding: .utf8) == "a1")
        #expect(try store.summaries(sessionID: "s").count == 2)
        // 修好权限后可以再恢复一次。
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        _ = try store.restoreBefore(plan, sessionID: "s") { _ in true }
        #expect(try String(contentsOf: a, encoding: .utf8) == "a0")
        #expect(try String(contentsOf: b, encoding: .utf8) == "b0")
    }

    @Test func overwriteConflictsSavesCurrentVersionAsCheckpointFirst() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        try Data("a0".utf8).write(to: a); try Data("b0".utf8).write(to: b)
        let store = try FileCheckpointStore(directory: root.appendingPathComponent("cp"), allowedRoots: [root])
        let t0 = Date().addingTimeInterval(-100)
        try change(store, a, to: "a1", at: t0)
        try change(store, b, to: "b1", at: t0.addingTimeInterval(10))
        try Data("b-external".utf8).write(to: b)
        let plan = try store.rewindPlan(before: try #require(store.summaries(sessionID: "s").last).id, sessionID: "s")
        _ = try store.restoreBefore(plan, sessionID: "s", overwriteConflicts: true) { _ in true }
        #expect(try String(contentsOf: a, encoding: .utf8) == "a0")
        #expect(try String(contentsOf: b, encoding: .utf8) == "b0")
        // 被覆盖的当前版本已存成检查点，可以恢复回来。
        let backup = try #require(store.summaries(sessionID: "s").first { $0.path == b.path })
        _ = try store.restore(backup.id, sessionID: "s")
        #expect(try String(contentsOf: b, encoding: .utf8) == "b-external")
    }

    @Test func oversizedConversationSnapshotDegradesToFileOnlyCheckpoint() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt")
        try Data("before".utf8).write(to: file)
        let store = try FileCheckpointStore(directory: root.appendingPathComponent("cp"), allowedRoots: [root])
        let huge = Data(repeating: 65, count: 16 * 1024 * 1024 + 1)
        let id = try store.begin(path: file, sessionID: "s", operation: .edit,
            expectedAfter: Data("after".utf8), conversation: huge)
        try Data("after".utf8).write(to: file)
        try store.commit(id)
        let summary = try #require(store.summaries(sessionID: "s").first)
        #expect(!summary.hasConversation)
        #expect(try store.restore(id, sessionID: "s") == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "before")
    }

    @Test func ordinarySourceNamesAreNotSensitiveButRealSecretsAre() {
        let base = "/synthetic/project/"
        for path in ["Sources/Keychain/KeychainStore.swift", "Sources/credentials.swift", "Sources/cookies.swift",
                     "docs/keychain.md"] {
            #expect(!SensitiveFilePolicy.contains(base + path), "\(path)")
        }
        for path in [".env", "certs/server.pem", "id_rsa", ".ssh/config", "Library/Keychains/login.keychain-db",
                     "credentials.json"] {
            #expect(SensitiveFilePolicy.contains(base + path), "\(path)")
            #expect(SensitiveFilePolicy.isUncheckpointedSecretFile(base + path), "\(path)")
        }
    }
}
