import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

/// 回合持续一段时间，方便在 A 会话产生转向后切到 B 会话观察 system prompt。
private final class IsolationProbeEngine: ComposerSnapshotForwardingTestEngine, @unchecked Sendable {
    var isAvailable: Bool { true }
    private let lock = NSLock()
    private(set) var calls: [(history: [ChatMessageUI], systemPrompt: String)] = []
    var delay: Duration = .seconds(2)
    private(set) var interruptIDs: [Int] = []

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        recordCall(history: history, systemPrompt: systemPrompt)
        let delay = delay
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.textDelta("probe"))
                try? await Task.sleep(for: delay)
                continuation.yield(.done(stopReason: .endTurn))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func interrupt() {}

    func interrupt(turnID: Int) {
        lock.lock()
        interruptIDs.append(turnID)
        lock.unlock()
    }

    func snapshotInterruptIDs() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return interruptIDs
    }

    func compactContext(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        keepRecent: Int
    ) async -> CompactionResult {
        CompactionResult(messages: [], summary: nil, compactedCount: 0)
    }

    private nonisolated func recordCall(history: [ChatMessageUI], systemPrompt: String) {
        lock.lock()
        calls.append((history, systemPrompt))
        lock.unlock()
    }

    func snapshotCalls() -> [(history: [ChatMessageUI], systemPrompt: String)] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

@Suite("会话执行上下文隔离")
@MainActor
struct ConversationIsolationTests {
    @Test func steerFromSessionADoesNotEnterSessionB() async throws {
        let chat = ChatStore()
        chat.newMessageInterruptsGeneration = { false }
        let engine = IsolationProbeEngine()
        chat.agentEngine = engine

        chat.draftText = "A 的任务"
        chat.sendDraft()
        try await Task.sleep(for: .milliseconds(40))

        chat.draftText = "只给 A 的转向"
        chat.sendDraft()
        let sessionA = try #require(chat.activeSessionID)

        chat.newSession()
        chat.draftText = "B 的任务"
        chat.sendDraft()

        var waited = 0
        while engine.snapshotCalls().count < 2 && waited < 200 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        let calls = engine.snapshotCalls()
        #expect(calls.count >= 2)
        #expect(!calls[1].systemPrompt.contains("只给 A 的转向"),
                "A 会话的转向不得通过全局状态注入 B 会话")

        chat.switchSession(id: sessionA)
        chat.stopStreaming()
        chat.newSession()
        chat.stopStreaming()
    }

    @Test func stopTargetsTheActiveConversationTurnOnly() async throws {
        let chat = ChatStore()
        let engine = IsolationProbeEngine()
        chat.agentEngine = engine

        chat.draftText = "A 的任务"
        chat.sendDraft()
        var waited = 0
        while engine.snapshotCalls().isEmpty && waited < 200 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        let sessionA = try #require(chat.activeSessionID)
        let turnA = try #require(chat.activeWritebackIdentity(for: sessionA)?.turnID)

        chat.newSession()
        chat.draftText = "B 的任务"
        chat.sendDraft()
        waited = 0
        while engine.snapshotCalls().count < 2 && waited < 200 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        let sessionB = try #require(chat.activeSessionID)
        let turnB = try #require(chat.activeWritebackIdentity(for: sessionB)?.turnID)

        chat.switchSession(id: sessionA)
        chat.stopStreaming()

        #expect(engine.snapshotInterruptIDs() == [turnA],
                "停止 A 只能取消 A 的稳定 turn identity，不得按全局最新回合误杀 B")
        #expect(!engine.snapshotInterruptIDs().contains(turnB))

        chat.newSession()
        chat.stopStreaming()
    }
}
