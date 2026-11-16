import Foundation
import Testing
@testable import MinisCore

/// W-b: a child task that inherits the parent's tool names must never be
/// offered the external-session tools, even when the parent policy allows them.
/// Status: 未运行 (not compiled when written).
@Suite("External session tools are not inherited by child tasks")
struct ExternalSessionChildInheritanceTests {
    @Test func inheritedChildCatalogOmitsExternalSessionTools() async throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("ext-session-child-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let source = try sessions.createSession(id: "ext-session-child-source")
        let controller = TurnController()
        let turn = await controller.beginTurn()
        defer { Task { await turn.finish() } }
        let parent = try ParentRuntimeIdentitySeed(sessionID: source.id, conversationID: source.id,
            taskID: "ext-session-child-parent", actorID: "owned-fixture").makeIdentity(using: turn)
        let owner = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let ledger = try minisCoreToolContractLedger(at: root)
        let provider = ScopedReadProbeProvider(path: root.appendingPathComponent("unused.txt").path, marker: "unused")
        // The parent policy explicitly allows both external-session tools.
        let policy = AgentCapabilityPolicy(allowedCapabilities: [.tools],
            allowedToolNames: ["file_read", ExternalSessionToolNames.read, ExternalSessionToolNames.send])
        let orchestrator = AgentOrchestrator(provider: provider, toolExecutor: owner,
            turnController: controller, currentConversationID: source.id,
            taskStore: AgentTaskStore(), sessionStore: sessions, toolExecutionFactLedger: ledger,
            parentID: parent.taskID, parentRuntimeIdentity: parent, parentTurnHandle: turn,
            runtimeMode: .production, capabilityPolicy: policy, parentCapabilities: [.tools],
            parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: owner))
        // No resourceRequest: the child takes the inherited tool-name path.
        let reports = await orchestrator.orchestrate(tasks: [SubAgentTask(id: "inheriting-child",
            title: "inheriting child", instructions: "read-no-file", requiredCapabilities: [.tools])],
            strategy: .sequential)
        #expect(reports.first?.result.isSuccess == true)
        #expect(provider.offeredToolNameSets == [["file_read"]])
    }
}
