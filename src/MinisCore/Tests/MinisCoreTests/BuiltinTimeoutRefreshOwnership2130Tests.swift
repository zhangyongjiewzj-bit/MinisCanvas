import Foundation
import Testing
@testable import MinisCore

private final class ScopedTimeoutReader2130: ToolExecutor, @unchecked Sendable {
    let builtin: BuiltinToolExecutor
    let context: AgentExecutionContextSnapshot
    let binding: TargetWorkspaceBinding
    private let lock = NSLock()
    private var started = false

    init(builtin: BuiltinToolExecutor, context: AgentExecutionContextSnapshot,
         binding: TargetWorkspaceBinding) {
        self.builtin = builtin
        self.context = context
        self.binding = binding
    }

    var hasStarted: Bool { lock.withLock { started } }

    func execute(name: String, input: [String: Any]) async throws -> String {
        lock.withLock { started = true }
        // This actual consumer reads the shared default while constructing
        // its scoped Builtin, then performs only a synthetic file read.
        return try await AgentExecutionContext.$current.withValue(context) {
            try await builtin.executeInTargetWorkspace(name: name, input: input, binding: binding)
        }
    }
}

@Suite("D-CONC2 MainActor timeout refresh and scoped Builtin consumer")
struct BuiltinTimeoutRefreshOwnership2130Tests {
    @Test
    func refreshPreservesSharedOwnerAndScopedFileDispatch() async throws {
        let root = try canonicalOwnedFixtureURL2130(
            URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"]))
        )
        let project = root.appendingPathComponent("project2130", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let inputFile = project.appendingPathComponent("owned2130.txt")
        try "synthetic2130".write(to: inputFile, atomically: true, encoding: .utf8)
        let source = ParentRuntimeIdentity(sessionID: "source2130", conversationID: "source2130",
            turnID: "turn-handle:99", taskID: "parent2130", actorID: "test")
        let tasks = AgentTaskStore()
        let metadata = SessionActionCreationMetadata(scopeID: "scope2130", idempotencyKey: "target2130",
            action: .new(title: "synthetic2130", projectID: "project2130", workingDirectory: project.path,
                         source: source))
        let task = try tasks.enqueueIdempotent(taskID: "target2130", parentID: source.taskID,
            providerID: "offline", modelID: "synthetic", creation: metadata).snapshot
        let run = try tasks.startRun(taskID: task.taskID, parentID: task.parentID, runID: "run2130")
        let controller = TurnController()
        let handle = await controller.beginTurn()
        let session = "producer2130"
        let parent = try ParentRuntimeIdentitySeed(sessionID: session, conversationID: session,
            taskID: task.taskID, actorID: "test").makeIdentity(using: handle)
        let context = AgentExecutionContextSnapshot(provider: MockLLMProvider(responses: []), approvalGate: nil,
            turnController: controller, currentConversationID: session, makeChildBudget: nil, deadline: nil,
            taskStore: tasks, parentTurnHandle: handle, parentRuntimeIdentity: parent)
        let builtin = BuiltinToolExecutor(allowedRoot: root, defaultShellTimeout: 300, deniedRoots: [])
        let reader = ScopedTimeoutReader2130(builtin: builtin, context: context,
            binding: TargetWorkspaceBinding(source: source, targetSessionID: session, taskID: task.taskID,
                runID: run.runID, projectID: "project2130", workingDirectory: project.path))
        #expect(builtin.defaultShellTimeout == 300)
        let reads = Task {
            await ConcurrentToolRunner(maxConcurrent: 4).run(
                (0..<64).map { ToolInvocation(id: "read2130-\($0)", name: "file_read",
                                             input: ["path": inputFile.path]) },
                executor: reader
            )
        }
        let refresh = Task { @MainActor in
            while !reader.hasStarted { await Task.yield() }
            for index in 0..<512 {
                // Same setter used by BridgeStore.refreshProductionAgentSettings.
                reader.builtin.defaultShellTimeout = index.isMultiple(of: 2) ? 300 : 45
                await Task.yield()
            }
        }
        let results = await reads.value
        await refresh.value
        #expect(results.count == 64)
        let everyReadSucceeded = results.allSatisfy { $0.isSuccess && $0.output?.contains("synthetic2130") == true }
        #expect(everyReadSucceeded)
        #expect(reader.builtin === builtin)
        #expect(builtin.defaultShellTimeout == 45)
        await handle.finish()
    }
    @Test func targetArtifactStillRejectsBackgroundUnderCapturedGlobalParent() async throws {
        let root = try minisCoreToolContractRoot("background-artifact").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let source = ParentRuntimeIdentity(sessionID: "background-artifact-source", conversationID: "background-artifact-source",
            turnID: "turn-handle:99", taskID: "background-artifact-parent", actorID: "test")
        let tasks = AgentTaskStore()
        let metadata = SessionActionCreationMetadata(scopeID: "artifact-scope", idempotencyKey: "artifact-target",
            action: .new(title: "owned", projectID: "artifact-project", workingDirectory: project.path, source: source))
        let task = try tasks.enqueueIdempotent(taskID: "artifact-target", parentID: source.taskID,
            providerID: "offline", modelID: "synthetic", creation: metadata).snapshot
        let run = try tasks.startRun(taskID: task.taskID, parentID: task.parentID, runID: "artifact-run")
        let controller = TurnController()
        let handle = await controller.beginTurn()
        defer { Task { await handle.finish() } }
        let session = "artifact-producer-" + UUID().uuidString
        let parent = try ParentRuntimeIdentitySeed(sessionID: session, conversationID: session,
            taskID: task.taskID, actorID: "test").makeIdentity(using: handle)
        let context = AgentExecutionContextSnapshot(provider: MockLLMProvider(responses: []), approvalGate: nil,
            turnController: controller, currentConversationID: session, makeChildBudget: nil, deadline: nil,
            taskStore: tasks, parentTurnHandle: handle, parentRuntimeIdentity: parent)
        let owner = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        var parentLoop = AgentLoop()
        try parentLoop.captureToolWorkspace(directory: root, owner: owner, projectScoped: false)
        let scope = try #require(parentLoop.childWorkspaceScope)
        #expect(scope.backgroundOrigin == .globalParent)
        let binding = TargetWorkspaceBinding(source: source, targetSessionID: session, taskID: task.taskID,
            runID: run.runID, projectID: "artifact-project", workingDirectory: project.path)
        await #expect(throws: ToolExecutorError.shellRejected("子任务或项目任务暂不支持后台命令")) {
            try await ChildToolWorkspaceScope.$current.withValue(scope) {
                try await AgentExecutionContext.$current.withValue(context) {
                    _ = try await owner.executeInTargetWorkspace(name: "shell_execute", input: [
                        "command": "pwd", "cwd": project.path, "run_in_background": true], binding: binding)
                }
            }
        }
        #expect(owner.backgroundShells.snapshots(sessionID: session).isEmpty)
    }
}

// Formal test roots may use a data-volume spelling that Foundation does not
// preserve in canonical policy URLs or enumerated child URL components.
// Normalize only this already-created owned fixture object; never a production
// allow-root or runner environment. Refuse any physical identity change.
private func canonicalOwnedFixtureURL2130(_ raw: URL) throws -> URL {
    let canonical = raw.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    let before = try FileManager.default.attributesOfItem(atPath: raw.path)
    let after = try FileManager.default.attributesOfItem(atPath: canonical.path)
    for key in [FileAttributeKey.systemNumber, .systemFileNumber, .ownerAccountID] {
        guard let original = before[key] as? NSNumber,
              let resolved = after[key] as? NSNumber,
              original == resolved else {
            throw NSError(domain: "MinisCanvas.OwnedFixtureCanonicalIdentity", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Fixture canonicalization changed device, inode or owner"])
        }
    }
    let metadata: [String: Any] = [
        "event": "CORE424_OWNED_FIXTURE_CANONICAL_IDENTITY",
        "helper": "canonicalOwnedFixtureURL2130",
        "sampling_point": "after_identity_guard_before_return",
        "sampled_at_epoch": Date().timeIntervalSince1970,
        "original_path": raw.path,
        "stable_path": canonical.path,
        "before": ["device": before[.systemNumber]!,
                   "inode": before[.systemFileNumber]!,
                   "UID": before[.ownerAccountID]!],
        "after": ["device": after[.systemNumber]!,
                  "inode": after[.systemFileNumber]!,
                  "UID": after[.ownerAccountID]!]
    ]
    let encoded = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
    print("CORE424_FIXTURE_METADATA " + String(decoding: encoded, as: UTF8.self))
    return canonical
}
