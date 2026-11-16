import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

private final class DelayedPlainTextProvider: LLMProvider, @unchecked Sendable {
    let delay: Duration
    var model = LLMModel(id: "turn-isolation", displayName: "Turn Isolation", provider: "Test")
    var name: String { "Turn Isolation Provider" }
    var capabilities: Set<ProviderCapability> { [] }

    init(delay: Duration = .milliseconds(120)) {
        self.delay = delay
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        try await Task.sleep(for: delay)
        return LLMResponse(text: "完成 \(messages.last?.content ?? "")", stopReason: "end_turn", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

@Suite("AgentLoop 生产回合停止隔离")
@MainActor
struct AgentLoopTurnIsolationTests {
    @Test func interruptingOneTurnDoesNotCancelSiblingTurn() async throws {
        let workspaceID = "turn-isolation-workspace"
        let revision = "turn-isolation-policy"
        let grantEpoch = "turn-isolation-epoch"
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: workspaceID, revision: revision, grantEpoch: grantEpoch,
            leaseID: "turn-isolation-lease", expiresAt: .distantFuture,
            autonomyCeiling: .l1
        )
        let engine = AgentLoopChatEngine(composerPolicyFacts: facts)
        let provider = DelayedPlainTextProvider()
        let historyA = [ChatMessageUI(role: .user, content: "A")]
        let historyB = [ChatMessageUI(role: .user, content: "B")]
        let skillsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("turn-isolation-\(UUID().uuidString)", isDirectory: true)
        let skillStore = SkillStore(skillsRoot: skillsRoot)
        defer { try? FileManager.default.removeItem(at: skillsRoot) }
        func frozenTurn(
            sessionID: String, turnID: Int, messageID: UUID
        ) -> (ComposerSubmissionSnapshot, AgentExecutionIdentity, ChatTurnRuntimeSnapshot) {
            let turn = AgentTurnIdentity(
                sessionID: sessionID, turnID: turnID, messageID: messageID.uuidString
            )
            let snapshot = ComposerSubmissionSnapshot(
                mode: .manual, approvalScope: .request, effort: .standard,
                sessionID: sessionID, turnID: turnID,
                taskID: "turn-isolation-task-\(turnID)",
                attemptID: "turn-isolation-attempt-\(turnID)",
                messageID: turn.messageID, inputDigest: "turn-isolation-input-\(turnID)",
                workspaceID: workspaceID, createdAt: Date(),
                policyRevision: revision, grantEpoch: grantEpoch,
                autonomyCeiling: .l1
            )
            let execution = AgentExecutionIdentity(
                turn: turn, operationID: "turn-isolation-operation-\(turnID)", attempt: 1
            )
            let runtime = ChatTurnRuntimeSnapshot(
                turn: turn,
                skillInjector: SkillInjector(store: skillStore).snapshotForTurn(),
                mcpBridge: nil
            )
            return (snapshot, execution, runtime)
        }
        let (snapshotA, executionA, runtimeA) = frozenTurn(
            sessionID: "conversation-A", turnID: 101, messageID: historyA[0].id
        )
        let (snapshotB, executionB, runtimeB) = frozenTurn(
            sessionID: "conversation-B", turnID: 202, messageID: historyB[0].id
        )
        let streamA = try await engine.streamReply(
            provider: provider, history: historyA, systemPrompt: "A", maxTokens: 64,
            conversationID: "conversation-A", authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil, turnID: 101,
            composerSnapshot: snapshotA, executionIdentity: executionA,
            turnRuntimeSnapshot: runtimeA
        )
        let streamB = try await engine.streamReply(
            provider: provider, history: historyB, systemPrompt: "B", maxTokens: 64,
            conversationID: "conversation-B", authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil, turnID: 202,
            composerSnapshot: snapshotB, executionIdentity: executionB,
            turnRuntimeSnapshot: runtimeB
        )

        let consumeA = Task { () -> (text: String, interrupted: Bool) in
            var text = ""
            do {
                for try await event in streamA {
                    if case .textDelta(let delta) = event { text += delta }
                }
                return (text, false)
            } catch {
                return (text, error is InterruptedError)
            }
        }
        let consumeB = Task { () -> String in
            var text = ""
            do {
                for try await event in streamB {
                    if case .textDelta(let delta) = event { text += delta }
                }
            } catch {
                return "error: \(error)"
            }
            return text
        }

        try await Task.sleep(for: .milliseconds(20))
        engine.interrupt(turnID: 101)

        let resultA = await consumeA.value
        let resultB = await consumeB.value
        #expect(resultA.interrupted, "A 应由自己的 turn controller 停止")
        #expect(resultB == "完成 B", "B 不得被 A 的停止信号取消")
    }
}
