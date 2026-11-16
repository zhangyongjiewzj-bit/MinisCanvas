import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Captured composer thinking in child-capable turns")
struct ChildTurnThinkingSnapshotTests {
    @Test func preparedAndSettingsCopiesRetainFrozenThinking() async throws {
        let turn = AgentTurnIdentity(sessionID: "synthetic-session", turnID: 1, messageID: "synthetic-message")
        let captured = ChatTurnRuntimeSnapshot(turn: turn, thinkingLevel: .high,
            skillInjector: nil, skillsDisabled: true, mcpBridge: nil)
        let effective = captured.withEffectiveSettings(nil, operationID: "synthetic-operation", required: false)
        let prepared = try #require(await effective.preparedForExecution())
        #expect(prepared.thinkingLevel == .high)
        let binding = ParentContextSnapshotV1(providerID: "synthetic-provider", modelID: "synthetic-model",
            configurationFingerprint: "synthetic-fingerprint",
            reasoningConfiguration: prepared.thinkingLevel?.rawValue, conversationID: turn.sessionID)
        let loop = try AgentLoop().withParentBinding(binding)
        #expect(loop.parentBinding?.reasoningConfiguration == "high")
        #expect(loop.parentBinding?.conversationID == turn.sessionID)
        let different = ParentContextSnapshotV1(providerID: "synthetic-provider", modelID: "synthetic-model",
            configurationFingerprint: "synthetic-fingerprint", reasoningConfiguration: "low", conversationID: turn.sessionID)
        do {
            _ = try loop.withParentBinding(different)
            Issue.record("A bound turn cannot change its frozen thinking level")
        } catch AgentLoopError.executionIdentityMismatch { }
    }
}
