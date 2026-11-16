import Foundation
import Testing
@testable import MinisCore

@Suite("P03 task isolation input and execution binding")
struct ChildWorktreeConsumerTests {
    @Test func taskLevelEnumIsConsumedWithoutWeakeningOtherTaskKeys() throws {
        var input: [String: Any] = ["input_version": 2, "tasks": [
            ["id": "one", "title": "One", "instructions": "Work", "isolation": "worktree"],
            ["id": "two", "title": "Two", "instructions": "Work"]]]
        let values = try OrchestrationToolExecutor.takeTaskIsolations(from: &input)
        #expect(values == ["one": .worktree])
        let decoded = try OrchestrateRequestV1.decode(input: input, maxTasks: 2)
        #expect(decoded.tasks.count == 2)
        for invalid in ["unknown" as Any, 1, NSNull()] {
            var bad: [String: Any] = ["tasks": [["id": "one", "isolation": invalid]]]
            #expect(throws: ToolExecutorError.self) { try OrchestrationToolExecutor.takeTaskIsolations(from: &bad) }
        }
        var extra: [String: Any] = ["input_version": 2, "tasks": [[
            "id": "one", "title": "One", "instructions": "Work", "isolation": "worktree",
            "isolation_path": "/model-must-not-allocate-this"]]]
        _ = try OrchestrationToolExecutor.takeTaskIsolations(from: &extra)
        #expect(throws: (any Error).self) { try OrchestrateRequestV1.decode(input: extra, maxTasks: 1) }
    }

    @Test func runtimeAllocationKeysAreRejectedButOtherUnknownKeysRemainTolerated() throws {
        let keys = ["repo", "path", "branch", "ref", "isolation_repo", "isolation_path",
                    "isolation_branch", "isolation_ref", "repository_path", "worktree_path"]
        for key in keys {
            for isolation in ["none", "worktree"] {
                var input: [String: Any] = ["input_version": 2, "tasks": [[
                    "id": "one", "title": "One", "instructions": "Work", "isolation": isolation,
                    key: NSNull()]]]
                _ = try OrchestrationToolExecutor.takeTaskIsolations(from: &input)
                #expect(throws: ToolExecutorError.invalidParameter("tasks.\(key)")) {
                    try OrchestrateRequestV1.decode(input: input, maxTasks: 1)
                }
            }
        }
        var input: [String: Any] = ["input_version": 2, "tasks": [[
            "id": "one", "title": "One", "instructions": "Work", "isolation": "worktree",
            "context": "Read /project/docs and discuss branch/ref in prose",
            "model_binding": ["kind": "inherit_parent"],
            "unknown_path_hint": "/ordinary/unknown", "future_option": true]]]
        let isolations = try OrchestrationToolExecutor.takeTaskIsolations(from: &input)
        #expect(isolations == ["one": .worktree])
        let decoded = try OrchestrateRequestV1.decode(input: input, maxTasks: 1)
        #expect(decoded.tasks.first?.context == "Read /project/docs and discuss branch/ref in prose")
        #expect(decoded.tasks.first?.modelBinding == .inheritParent)
    }

    @Test func oldPersistedTaskDefaultsToNoneAndRuntimeCopiesKeepIsolation() throws {
        let original = SubAgentTask(id: "task", title: "Task", instructions: "Work")
        let bytes = try JSONEncoder().encode(original)
        var old = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        old.removeValue(forKey: "isolation")
        let restored = try JSONDecoder().decode(SubAgentTask.self, from: JSONSerialization.data(withJSONObject: old))
        #expect((restored.isolation ?? SubAgentIsolation.none) == .none)
        let isolated = restored.withIsolation(.worktree).withExecutionID("fresh")
            .resolvedBinding(providerID: "provider", modelID: "model", configurationFingerprint: "fp", source: .inherited)
        #expect(isolated.isolation == .worktree)
        #expect(try JSONDecoder().decode(SubAgentTask.self, from: JSONEncoder().encode(isolated)).isolation == .worktree)
    }

    @Test func unavailableIsolationDoesNotRunAnUnisolatedChild() async {
        let orchestrator = AgentOrchestrator(runtimeMode: .production)
        let reports = await orchestrator.orchestrate(tasks: [
            SubAgentTask(id: "isolated", title: "Task", instructions: "Work", isolation: .worktree)
        ], strategy: .sequential)
        #expect(reports.count == 1)
        #expect(reports.first?.result.isSuccess == false)
        #expect(reports.first?.result.error?.contains("WORKTREE_ISOLATION_UNAVAILABLE") == true)
    }

    @Test func exactScopeIsSingleUseAndRevocationPreventsReuse() async throws {
        let fixture = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("child-scope-\(UUID().uuidString)")
        let project = fixture.appendingPathComponent("project")
        let checkout = fixture.appendingPathComponent("checkout")
        for directory in [project, checkout] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: fixture) }
        let uuid = UUID(), now = Date()
        let task = SubAgentTask(id: "task", title: "Task", instructions: "Work", isolation: .worktree,
            executionID: "parent:execution:\(uuid.uuidString)", parentContextSnapshotID: "parent-context")
        let allocation = GitChildWorktreeAllocation(identity: .init(taskID: task.id, executionID: uuid,
            parentSessionID: "parent-session", parentContextSnapshotID: "parent-context"),
            repositoryPath: project.path, workingDirectory: checkout.path, branch: "minis/child-\(uuid.uuidString.lowercased())")
        let goal = GoalEnvelope(scopeID: "scope", allowedCapabilities: ["file_read"], fileRoots: [checkout.path],
            budget: 10, deadline: now.addingTimeInterval(60))
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID, issuedAt: now,
            expiresAt: goal.deadline)
        let facts = ComposerPolicyFactSource(knownCapabilities: ["file_read"], grantedCapabilities: ["file_read"],
            allowedWriteRoots: [checkout.path], workspaceID: "workspace", revision: "revision",
            grantEpoch: "epoch", leaseID: "lease", expiresAt: goal.deadline)
        let owner = BuiltinToolExecutor(allowedRoot: project, deniedRoots: [], additionalAllowedRoots: [checkout])
        let scope = try ChildWorktreeExecutionScope(allocation: allocation, task: task, owner: owner,
            executor: PolicyEnforcedToolExecutor(base: owner, goal: goal, lease: lease), goal: goal, lease: lease, facts: facts,
            cleanupParentAuthority: {})
        let activeResource = try await scope.currentSnapshot()
        #expect(activeResource.taskIsActive && activeResource.parentAuthorityValid)
        await #expect(throws: (any Error).self) {
            try await scope.withExclusiveCleanupAccess(expected: activeResource) { _ in
                Issue.record("active execution must not enter cleanup")
                return GitChildWorktreeCleanupResult(originalPath: checkout.path, trashURL: checkout, message: "synthetic")
            }
        }
        #expect(!scope.claim(task: task.withExecutionID("different-execution")))
        #expect(scope.claim(task: task))
        #expect(!scope.claim(task: task))
        scope.revoke()
        #expect(!scope.isActive)
        #expect(!scope.claim(task: task))
        let endedResource = try await scope.currentSnapshot()
        #expect(!endedResource.taskIsActive && endedResource.childScopeRevoked)
        #expect(endedResource.parentAuthorityValid) // execution revoke is not parent permission revoke
        #expect(endedResource.generation != activeResource.generation)
        await #expect(throws: (any Error).self) {
            try await scope.withExclusiveCleanupAccess(expected: activeResource) { _ in
                Issue.record("stale generation must not enter cleanup")
                return GitChildWorktreeCleanupResult(originalPath: checkout.path, trashURL: checkout, message: "synthetic")
            }
        }
        try await scope.validateExactWorktreePath(allocation)
        let renamed = fixture.appendingPathComponent("original-checkout")
        try FileManager.default.moveItem(at: checkout, to: renamed)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) { try await scope.validateExactWorktreePath(allocation) }
        try FileManager.default.removeItem(at: checkout)
        try FileManager.default.moveItem(at: renamed, to: checkout)
        _ = try await scope.withExclusiveCleanupAccess(expected: endedResource) { _ in
            return GitChildWorktreeCleanupResult(originalPath: checkout.path, trashURL: checkout, message: "synthetic effect only")
        }
        #expect(try await scope.currentSnapshot().parentAuthorityValid == false)
        await #expect(throws: (any Error).self) {
            try await scope.withExclusiveCleanupAccess(expected: endedResource) { _ in
                Issue.record("retired resource cannot be reused")
                return GitChildWorktreeCleanupResult(originalPath: checkout.path, trashURL: checkout, message: "synthetic")
            }
        }
        let deniedOwner = BuiltinToolExecutor(allowedRoot: project, deniedRoots: [checkout], additionalAllowedRoots: [checkout])
        #expect(throws: (any Error).self) {
            try ChildWorktreeExecutionScope(allocation: allocation, task: task, owner: deniedOwner,
                executor: PolicyEnforcedToolExecutor(base: deniedOwner, goal: goal, lease: lease),
                goal: goal, lease: lease, facts: facts)
        }
    }
}
