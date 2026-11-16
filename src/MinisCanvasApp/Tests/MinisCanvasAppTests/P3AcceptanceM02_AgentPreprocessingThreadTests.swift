import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private func isMainThreadDuringContextPreparation() -> Bool {
    Thread.isMainThread
}

@Suite("D-PERF-06 Agent context preparation executor")
@MainActor
struct P3AcceptanceM02_AgentPreprocessingThreadTests {
    @Test("normal Agent turn prepares context away from the UI main thread")
    func contextPreparationRunsOutsideMainThread() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("m02-perf06-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceID = "m02-perf06-synthetic-workspace"
        let turn = AgentTurnIdentity(
            sessionID: "m02-perf06-synthetic-session", turnID: 1,
            messageID: "assistant:m02-perf06-synthetic-session:1"
        )
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: workspaceID, revision: "m02-perf06-policy",
            grantEpoch: "m02-perf06-epoch", leaseID: "m02-perf06-lease",
            expiresAt: Date().addingTimeInterval(300), autonomyCeiling: .l3
        )
        let composerSnapshot = ComposerSubmissionSnapshot(
            mode: .auto, approvalScope: .request, effort: .standard,
            sessionID: turn.sessionID, turnID: turn.turnID,
            taskID: "m02-perf06-task", attemptID: "m02-perf06-attempt",
            messageID: turn.messageID, inputDigest: "m02-perf06-input",
            workspaceID: workspaceID, createdAt: Date(),
            policyRevision: facts.revision, grantEpoch: facts.grantEpoch,
            autonomyCeiling: facts.autonomyCeiling
        )
        let engine = AgentLoopChatEngine(
            toolExecutor: BuiltinToolExecutor(allowedRoot: root),
            maxIterations: 1,
            onContextPreparation: {
                #expect(!isMainThreadDuringContextPreparation())
            },
            composerPolicyFacts: facts
        )
        let runtimeSnapshot = ChatTurnRuntimeSnapshot(
            turn: turn,
            skillInjector: SkillInjector(
                store: SkillStore(skillsRoot: root.appendingPathComponent("skills"))
            ).snapshotForTurn(),
            mcpBridge: nil
        )

        // A valid normal turn must reach preparation before the synthetic
        // provider. The callback assertion observes its actual executor.
        let stream = try await engine.streamReply(
            provider: MockProvider.shared,
            history: [ChatMessageUI(role: .user, content: "synthetic question")],
            systemPrompt: "synthetic system prompt", maxTokens: 64,
            conversationID: turn.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: turn.turnID,
            composerSnapshot: composerSnapshot,
            executionIdentity: AgentExecutionIdentity(turn: turn),
            turnRuntimeSnapshot: runtimeSnapshot
        )
        var sawTerminal = false
        for try await event in stream {
            if case .done = event { sawTerminal = true }
        }
        #expect(sawTerminal)
    }
}
