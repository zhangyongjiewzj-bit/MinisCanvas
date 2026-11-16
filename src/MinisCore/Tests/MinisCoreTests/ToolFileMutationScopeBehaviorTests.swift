import Foundation
import Testing
@testable import MinisCore

@Suite struct ToolFileMutationScopeBehaviorTests {
    @Test func symlinkAliasWritersShareLockCancellationAndSuccessorHasRealEffect() async throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("goal18-alias-writers-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        #expect(root.path.hasPrefix(profile.rootDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target.txt")
        let alias = root.appendingPathComponent("alias.txt")
        try "seed".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let key = PolicyRuntimePathBoundary.foldedForPathComparison(target.path)
        let token = UUID()
        _ = try await ToolFileMutationSerialiser.shared.acquire(key: key, token: token)
        let first = Task { try await executor.execute(name: "file_write",
            input: ["path": target.path, "content": "A", "append": true]) }
        let second = Task { try await executor.execute(name: "file_write",
            input: ["path": alias.path, "content": "B", "append": true]) }
        let deadline = ContinuousClock.now + .seconds(2)
        while await ToolFileMutationSerialiser.shared.waitingCount(key: key) < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await ToolFileMutationSerialiser.shared.waitingCount(key: key) == 2)
        first.cancel()
        do { _ = try await first.value; Issue.record("cancelled queued write must not execute") }
        catch { #expect(error is CancellationError) }
        await ToolFileMutationSerialiser.shared.release(key: key, token: token)
        _ = try await second.value
        #expect(try String(contentsOf: target, encoding: .utf8) == "seedB")
        _ = try await executor.execute(name: "file_write",
            input: ["path": target.path, "content": "C", "append": true])
        #expect(try String(contentsOf: alias, encoding: .utf8) == "seedBC")
    }

    @Test func hardLinkAliasesAreRefusedBeforeAnyMutation() async throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("goal18-hardlink-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        #expect(root.path.hasPrefix(profile.rootDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target.txt")
        let alias = root.appendingPathComponent("hardlink.txt")
        try "seed".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: target, to: alias)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        for path in [target.path, alias.path] {
            let calls: [(String, [String: Any])] = [
                ("file_write", ["path": path, "content": "bad", "append": true]),
                ("file_edit", ["path": path, "old_string": "seed", "new_string": "bad"]),
                ("file_delete", ["path": path])
            ]
            for (name, input) in calls {
                do {
                    _ = try await executor.execute(name: name, input: input)
                    Issue.record("hard-link mutation must be refused")
                } catch { #expect(error.localizedDescription.contains("硬链接")) }
            }
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "seed")
        #expect(try String(contentsOf: alias, encoding: .utf8) == "seed")
    }
}
