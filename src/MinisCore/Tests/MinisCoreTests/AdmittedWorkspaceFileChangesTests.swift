import Foundation
import Testing
@testable import MinisCore

@Suite("Admitted project checkpoint and ledger roots")
struct AdmittedWorkspaceFileChangesTests {
    @Test(arguments: [true, false])
    func projectSwitchAndMountKeepFileChangesWithCheckpointsOnOrOff(checkpoints: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("admitted-writes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let physical = root.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: physical) }
        let a = physical.appendingPathComponent("a"), b = physical.appendingPathComponent("b")
        let mount = physical.appendingPathComponent("mount")
        for directory in [a, b, mount] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let initial = physical.appendingPathComponent("projectless-identity")
        let provider: @Sendable () -> [URL] = {
            AdmittedFileWorkspaceRoots.currentWriteRoots(fallback: [])
        }
        let ledger = FileChangeLedger(workspaceRoot: initial.path, rootsProvider: provider)
        let store = try FileCheckpointStore(directory: physical.appendingPathComponent("checkpoints"),
            allowedRoots: [], allowedRootsProvider: provider)
        let owner = BuiltinToolExecutor(allowedRoot: initial, deniedRoots: [],
            additionalAllowedRoots: [mount], sessionDerivedRoot: true)
        owner.fileChangeLedger = ledger
        owner.fileChangeSessionID = "synthetic-session"
        owner.fileCheckpointsEnabled = checkpoints
        owner.fileCheckpointStore = checkpoints ? store : nil
        for (directory, targetRoot) in [(a, a), (b, b), (b, mount)] {
            var loop = AgentLoop()
            try loop.captureToolWorkspace(directory: directory, owner: owner)
            let scope = try #require(loop.childWorkspaceScope)
            try await ChildToolWorkspaceScope.$current.withValue(scope) {
                let target = targetRoot.appendingPathComponent("note.txt")
                let written = try await owner.execute(name: "file_write", input: ["path": target.path, "content": "one"])
                #expect(written.contains("diffID:"))
                let edited = try await owner.execute(name: "file_edit", input: ["path": target.path, "old_string": "one", "new_string": "two"])
                #expect(edited.contains("diffID:"))
                #expect(try String(contentsOf: target, encoding: .utf8) == "two")
                if checkpoints {
                    let deleted = try await owner.execute(name: "file_delete", input: ["path": target.path])
                    #expect(deleted.contains("diffID:"))
                    #expect(!FileManager.default.fileExists(atPath: target.path))
                }
            }
        }
        let records = ledger.records(sessionID: "synthetic-session")
        #expect(records.count == (checkpoints ? 9 : 6))
        #expect(Set(records.compactMap(\.workspaceRoot)) == Set([a.path, b.path, mount.path]))
        #expect(Set(records.map(\.diffID)).count == records.count)
        #expect(records.allSatisfy { $0.path == "note.txt" })
        if checkpoints {
            #expect(try store.summaries(sessionID: "synthetic-session").count == 9)
        }
    }

    @Test func explicitCeilingAlsoKeepsItsMountedDirectoryWritableInProjectScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("explicit-mount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let physical = root.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: physical) }
        let project = physical.appendingPathComponent("project"), mount = physical.appendingPathComponent("mount")
        for directory in [project, mount] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let owner = BuiltinToolExecutor(allowedRoot: project, deniedRoots: [], additionalAllowedRoots: [mount])
        let ledger = FileChangeLedger(workspaceRoot: project.path, rootsProvider: {
            AdmittedFileWorkspaceRoots.currentWriteRoots(fallback: [project, mount])
        })
        owner.fileChangeLedger = ledger
        owner.fileChangeSessionID = "synthetic-session"
        var loop = AgentLoop()
        try loop.captureToolWorkspace(directory: project, owner: owner)
        let scope = try #require(loop.childWorkspaceScope)
        try await ChildToolWorkspaceScope.$current.withValue(scope) {
            let target = mount.appendingPathComponent("note.txt")
            let output = try await owner.execute(name: "file_write", input: ["path": target.path, "content": "mounted"])
            #expect(output.contains("diffID:"))
            #expect(try await owner.execute(name: "file_read", input: ["path": target.path]) == "     1\tmounted")
        }
        #expect(ledger.records(sessionID: "synthetic-session").first?.workspaceRoot == mount.path)
    }

    @Test func newRecordRootSurvivesEncodingAndLegacyRecordStillDecodes() throws {
        let ledger = FileChangeLedger(workspaceRoot: "/synthetic/original",
            rootsProvider: { [URL(fileURLWithPath: "/synthetic/selected")] })
        let record = try ledger.register(sessionID: "synthetic-session", path: "/synthetic/selected/note.txt",
            kind: .created, oldContent: nil, newContent: "synthetic")
        #expect(record.workspaceRoot == "/synthetic/selected")
        let encoded = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(FileChangeRecord.self, from: encoded) == record)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "workspaceRoot")
        let legacy = try JSONDecoder().decode(FileChangeRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.workspaceRoot == nil)
        #expect(legacy.path == "note.txt")
    }
}
