import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// Re-anchored from 11e6fe287. Poll bounds below observe lifecycle completion,
// not elapsed performance; executor and identity assertions are discriminating.
// Synchronous probe executes at the production detached callback's current
// thread. It does not schedule a task or hop to a different executor.
private func isMainThreadDuringPromptPreprocessing() -> Bool {
    Thread.isMainThread
}

private actor SyntheticTurnPreparationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var didEnter = false
    private var isReleased = false

    var entered: Bool { didEnter }

    func wait() async {
        didEnter = true
        if isReleased { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private actor SyntheticTurnProviderCounter {
    private var count = 0
    var calls: Int { count }
    func record() { count += 1 }
}

private struct SyntheticTurnProvider: LLMProvider {
    let name = "preprocess-offline"
    var model = LLMModel(
        id: "preprocess-offline", displayName: "Preprocess Offline", provider: "test"
    )
    let counter: SyntheticTurnProviderCounter

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        await counter.record()
        return LLMResponse(text: "offline", stopReason: "end_turn", usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await counter.record()
        return AsyncThrowingStream { continuation in
            continuation.yield(.finished(stopReason: "end_turn"))
            continuation.finish()
        }
    }
}

private final class SyntheticTurnRecordingEngine: ChatAgentEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPrompts: [String] = []
    var prompts: [String] { lock.withLock { recordedPrompts } }
    var isAvailable: Bool { true }

    func streamReply(
        provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        try await deliver(provider: provider, history: history,
                          systemPrompt: systemPrompt, maxTokens: maxTokens)
    }

    func streamReply(
        provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, maxTokens: Int,
        conversationID: String?, authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?, turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot,
        executionIdentity: AgentExecutionIdentity,
        turnRuntimeSnapshot: ChatTurnRuntimeSnapshot
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        guard executionIdentity.turn == turnRuntimeSnapshot.turn,
              composerSnapshot.sessionID == executionIdentity.turn.sessionID,
              composerSnapshot.turnID == executionIdentity.turn.turnID else {
            throw ChatTurnRuntimeSnapshotError.identityMismatch
        }
        return try await deliver(provider: provider, history: history,
                                 systemPrompt: systemPrompt, maxTokens: maxTokens)
    }

    // Match the production protocol: the provider stays on the caller executor.
    private nonisolated(nonsending) func deliver(
        provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        lock.withLock { recordedPrompts.append(systemPrompt) }
        _ = try await provider.streamMessage(
            messages: history.map { $0.asLLMMessage() }, systemPrompt: systemPrompt,
            maxTokens: maxTokens, temperature: nil
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(.done(stopReason: .endTurn))
            continuation.finish()
        }
    }

    func interrupt() {}

    func compactContext(
        provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, keepRecent: Int
    ) async -> CompactionResult {
        CompactionResult(messages: [], summary: nil, compactedCount: 0)
    }
}

@Suite("D-PERF-06 ordinary turn off-main preparation")
@MainActor
struct OrdinaryTurnPreprocessTests {
    private func fixture(
        gate: SyntheticTurnPreparationGate
    ) -> (ChatStore, SyntheticTurnRecordingEngine, SyntheticTurnProviderCounter) {
        let chat = ChatStore()
        let engine = SyntheticTurnRecordingEngine()
        let counter = SyntheticTurnProviderCounter()
        let injector = SkillInjector(store: SkillStore(
            skillsRoot: URL(fileURLWithPath: "/dev/null/dev124-empty-skills")
        ))
        chat.agentEngine = engine
        chat.streamingProviderOverride = SyntheticTurnProvider(counter: counter)
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(
                turn: turn, skillInjector: injector.snapshotForTurn(), mcpBridge: nil
            )
        }
        chat.turnPromptPreprocessPauseForTests = {
            #expect(!isMainThreadDuringPromptPreprocessing())
            await gate.wait()
        }
        return (chat, engine, counter)
    }

    private func waitForGate(_ gate: SyntheticTurnPreparationGate) async throws {
        for _ in 0..<100 {
            if await gate.entered { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Detached preparation did not reach its synthetic gate")
    }

    @Test("paused preparation leaves MainActor Composer responsive and starts Provider once after release")
    func backgroundPreparationAndOnceOnlyProvider() async throws {
        let gate = SyntheticTurnPreparationGate()
        let (chat, engine, counter) = fixture(gate: gate)
        let owner = try #require(chat.activeSessionID)
        chat.pickerCatalogLoader = {
            [PickerCatalogItem(id: "plugin:old", kind: .plugin, name: "OldPlugin", detail: "offline")]
        }
        chat.loadPickerCatalog()
        #expect(chat.pickerCatalog.map(\.id) == ["plugin:old"])
        chat.draftText = "ordinary turn @OldPlugin"
        chat.submitComposer()
        try await waitForGate(gate)

        // This mutation runs while the detached preparation is deliberately
        // suspended. A synchronous MainActor prompt build would block here.
        chat.pickerCatalogLoader = {
            [PickerCatalogItem(id: "plugin:new", kind: .plugin, name: "NewPlugin", detail: "offline")]
        }
        chat.loadPickerCatalog()
        #expect(chat.pickerCatalog.map(\.id) == ["plugin:new"])
        chat.draftText = "next draft stays responsive"
        #expect(chat.draftText == "next draft stays responsive")
        #expect(chat.activeSessionID == owner)
        #expect(await counter.calls == 0)
        #expect(engine.prompts.isEmpty)

        await gate.release()
        for _ in 0..<100 {
            if await counter.calls == 1 && !chat.isActiveSessionStreaming { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await counter.calls == 1)
        let prompt = try #require(engine.prompts.first)
        #expect(engine.prompts.count == 1)
        #expect(prompt.contains(ChatStore.systemPrompt))
        #expect(!prompt.contains("ordinary turn"))
        #expect(prompt.contains("OldPlugin"))
        #expect(!prompt.contains("NewPlugin"))
    }

    @Test("stop during preparation prevents any Provider call or late receipts")
    func cancellationBeforeProvider() async throws {
        let gate = SyntheticTurnPreparationGate()
        let (chat, engine, counter) = fixture(gate: gate)
        chat.draftText = "cancel this turn"
        chat.submitComposer()
        try await waitForGate(gate)
        chat.stopStreaming()
        await gate.release()
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await counter.calls == 0)
        #expect(engine.prompts.isEmpty)
        #expect(!chat.isActiveSessionStreaming)
        #expect(chat.lastSkillInjectionReceipts.isEmpty)
    }

    @Test("same-session transcript revision change rejects a prepared stale turn")
    func transcriptRevisionChangeBeforeProvider() async throws {
        let gate = SyntheticTurnPreparationGate()
        let (chat, engine, counter) = fixture(gate: gate)
        let owner = try #require(chat.activeSessionID)
        chat.draftText = "frozen request"
        chat.submitComposer()
        try await waitForGate(gate)

        // Simulate a newer transcript mutation without changing the owner.
        // The old prompt must not call Provider against this newer revision.
        chat.appendUser("newer transcript event")
        await gate.release()
        for _ in 0..<100 {
            if chat.activeWritebackIdentity(for: owner) == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await counter.calls == 0)
        #expect(engine.prompts.isEmpty)
        #expect(chat.activeWritebackIdentity(for: owner) == nil)
        #expect(chat.messages(forSession: owner)?.last?.isStreaming == false)
    }

    @Test("switch during preparation retains the frozen old turn and isolates the new session")
    func sessionChangeRetainsFrozenTurnWithoutCrossOwnerWriteback() async throws {
        let gate = SyntheticTurnPreparationGate()
        let (chat, engine, counter) = fixture(gate: gate)
        let old = try #require(chat.activeSessionID)
        chat.draftText = "old frozen request"
        chat.submitComposer()
        try await waitForGate(gate)

        let fresh = chat.applyNewSession(title: "fresh")
        chat.turnPromptPreprocessPauseForTests = nil
        chat.draftText = "new owner request"
        chat.submitComposer()
        for _ in 0..<100 {
            if await counter.calls == 1 && !chat.isActiveSessionStreaming { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(chat.activeSessionID == fresh)
        #expect(await counter.calls == 1)
        #expect(engine.prompts.count == 1)

        await gate.release()
        for _ in 0..<100 {
            if await counter.calls == 2 && chat.activeWritebackIdentity(for: old) == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await counter.calls == 2)
        #expect(engine.prompts.count == 2)
        #expect(chat.activeSessionID == fresh)
        #expect(chat.activeWritebackIdentity(for: old) == nil)
        #expect(chat.messages(forSession: old)?.contains {
            $0.role == .user && $0.content.contains("old frozen request")
        } == true)
        #expect(chat.messages(forSession: fresh)?.contains {
            $0.role == .user && $0.content.contains("new owner request")
        } == true)
    }
}
