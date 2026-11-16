import Foundation
import Testing
@testable import MinisCore

@Suite("Child task file ownership")
struct ChildTaskFileOwnershipTests {
    @Test func childCheckpointsRestoreOnlyTheirOwnFilesAndKeepConflictFence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("child-ownership-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let physical = root.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: physical) }
        let store = try FileCheckpointStore(directory: physical.appendingPathComponent("checkpoints"), allowedRoots: [physical])
        let ledger = FileChangeLedger(workspaceRoot: physical.path)
        for task in ["a", "b"] {
            let target = physical.appendingPathComponent(task + ".txt")
            try Data("before".utf8).write(to: target)
            try ChildFileChangeOwnership.$current.withValue(.init(childTaskID: task,
                childSessionID: "child-" + task, parentSessionID: "parent")) {
                let id = try store.begin(path: target, sessionID: "child-" + task,
                    operation: .edit, expectedAfter: Data("after".utf8), parentSessionID: "parent")
                try Data("after".utf8).write(to: target)
                try store.commit(id)
                let record = try ledger.register(sessionID: "child-" + task, path: target.path,
                    kind: .modified, oldContent: "before", newContent: "after")
                #expect(record.childTaskID == task)
            }
        }
        #expect(try store.summaries(sessionID: "parent", childTaskID: "a").count == 1)
        #expect(try store.summaries(sessionID: "unrelated", childTaskID: "a").isEmpty)
        #expect(try store.restoreChildTask("a", sessionID: "parent").count == 1)
        #expect(try String(contentsOf: physical.appendingPathComponent("a.txt"), encoding: .utf8) == "before")
        let b = physical.appendingPathComponent("b.txt")
        try Data("user edit".utf8).write(to: b)
        do {
            _ = try store.restoreChildTask("b", sessionID: "parent")
            Issue.record("A newer edit must prevent child rollback")
        } catch FileCheckpointStore.Failure.changed { }
        #expect(try String(contentsOf: b, encoding: .utf8) == "user edit")
    }

    @Test func ownershipDoesNotLeakIntoAnotherSessionAndLegacyRecordsDecode() throws {
        let ledger = FileChangeLedger(workspaceRoot: "/synthetic")
        let record = try ChildFileChangeOwnership.$current.withValue(.init(childTaskID: "a",
            childSessionID: "child-a", parentSessionID: "parent")) {
            try ledger.register(sessionID: "other", path: "/synthetic/a.txt", kind: .created,
                oldContent: nil, newContent: "one")
        }
        #expect(record.childTaskID == nil)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json.removeValue(forKey: "childTaskID")
        let legacy = try JSONDecoder().decode(FileChangeRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.childTaskID == nil)
    }
}
