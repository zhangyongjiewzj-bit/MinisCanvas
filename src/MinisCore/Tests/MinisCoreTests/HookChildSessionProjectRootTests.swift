import Foundation
import Testing

@testable import MinisCore

// D-28: a project PreToolUse hook must also guard tool calls made by a
// sub-agent task. Child sessions are named "<parentSessionID>:child:<execID>"
// (AgentOrchestrator.makeChildRuntimeIdentity) while only the parent session
// registers the project root with HookRuntime.

private actor ChildHookDenyRunner: HookCommandRunning {
    private(set) var workingDirectories: [String?] = []
    private(set) var sessionIDs: [String] = []
    func run(_ request: HookCommandRequest) async -> HookCommandResult {
        workingDirectories.append(request.workingDirectory?.path)
        if let object = try? JSONSerialization.jsonObject(with: request.stdin) as? [String: Any],
           let session = object["session_id"] as? String {
            sessionIDs.append(session)
        }
        return HookCommandResult(exitCode: 2, stdout: Data(),
            stderr: Data("CHILD_HOOK_BLOCK".utf8), timedOut: false, launchError: nil)
    }
}

@Suite("Project hooks reach sub-agent task sessions", .serialized)
struct HookChildSessionProjectRootTests {
    private let parentSession = "00000000-0000-0000-0000-0000000000A1"
    private var childSession: String { "\(parentSession):child:exec-1" }

    private func call(session: String) throws -> ComposerHookInvocation {
        ComposerHookInvocation(callID: "call-\(session.count)", capability: "shell_execute",
            input: try ComposerToolInput(["command": "echo synthetic"]),
            identityDigest: "identity", sessionID: session)
    }

    private func project(_ root: URL, withDenyHook: Bool) throws -> URL {
        let project = root.appendingPathComponent("project")
        if withDenyHook {
            let config = project.appendingPathComponent(HookConfigStore.projectRelativePath)
            try FileManager.default.createDirectory(
                at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            let file = HookConfigurationFile(hooks: [
                HookDefinition(id: "deny-shell", event: .preToolUse, matcher: "shell_execute",
                    command: "exit 2")])
            try JSONEncoder().encode(file).write(to: config)
        } else {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        }
        return project
    }

    @Test("a trusted project PreToolUse deny also denies the child task's tool call")
    func projectDenyAppliesToChildSession() async throws {
        let root = try minisCoreToolContractRoot("d28-child-project-hook")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try project(root, withDenyHook: true)
        let store = HookConfigStore(directory: root.appendingPathComponent("state"))
        let hash = try #require(store.projectSnapshot(projectRoot: project).contentHash)
        try store.trustProjectHooks(projectRoot: project, expectedHash: hash)
        let runner = ChildHookDenyRunner()
        let runtime = HookRuntime(store: store, runner: runner, environment: { [:] })
        runtime.registerSessionRoot(sessionID: parentSession, projectRoot: project)

        let parent = try await runtime.preToolUse(try call(session: parentSession))
        #expect(parent.hasDecision && parent.verdict == .deny)

        let child = try await runtime.preToolUse(try call(session: childSession))
        #expect(child.hasDecision && child.verdict == .deny)
        #expect(child.reason == "CHILD_HOOK_BLOCK")
        #expect(child.invocationIdentityDigest == "identity")
        let directories = await runner.workingDirectories
        #expect(directories.count == 2)
        #expect(directories.last.flatMap { $0 } == project.path)
    }

    @Test("a nested child resolves the same project root as its root session")
    func projectDenyAppliesToNestedChildSession() async throws {
        let root = try minisCoreToolContractRoot("d28-nested-child-project-hook")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try project(root, withDenyHook: true)
        let store = HookConfigStore(directory: root.appendingPathComponent("state"))
        let hash = try #require(store.projectSnapshot(projectRoot: project).contentHash)
        try store.trustProjectHooks(projectRoot: project, expectedHash: hash)
        let runtime = HookRuntime(store: store, runner: ChildHookDenyRunner(), environment: { [:] })
        runtime.registerSessionRoot(sessionID: parentSession, projectRoot: project)

        let nested = try await runtime.preToolUse(
            try call(session: "\(childSession):child:exec-2"))
        #expect(nested.hasDecision && nested.verdict == .deny)
    }

    @Test("without any project hook the child task's tool call stays undecided")
    func childRunsNormallyWithoutProjectHook() async throws {
        let root = try minisCoreToolContractRoot("d28-child-no-hook")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try project(root, withDenyHook: false)
        let store = HookConfigStore(directory: root.appendingPathComponent("state"))
        let runner = ChildHookDenyRunner()
        let runtime = HookRuntime(store: store, runner: runner, environment: { [:] })
        runtime.registerSessionRoot(sessionID: parentSession, projectRoot: project)

        let child = try await runtime.preToolUse(try call(session: childSession))
        #expect(!child.hasDecision && child.verdict == .allow)
        #expect(await runner.workingDirectories.isEmpty)
    }

    @Test("a child of a session that never registered a root gets no project hooks")
    func childOfUnregisteredSessionHasNoRoot() async throws {
        let root = try minisCoreToolContractRoot("d28-child-unregistered")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HookConfigStore(directory: root.appendingPathComponent("state"))
        let runtime = HookRuntime(store: store, runner: ChildHookDenyRunner(), environment: { [:] })
        let child = try await runtime.preToolUse(try call(session: childSession))
        #expect(!child.hasDecision && child.verdict == .allow)
    }
}
