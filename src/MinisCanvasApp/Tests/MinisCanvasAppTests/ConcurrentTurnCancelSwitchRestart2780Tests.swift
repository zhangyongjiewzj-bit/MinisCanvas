import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// Only the transport is controlled. Every send, cancellation, identity,
// persistence write and fresh-store read uses the production consumer.
private actor Turn2780Transport {
    typealias Continuation = AsyncThrowingStream<LLMAssistantStreamEvent, Error>.Continuation
    private var continuations: [Int: Continuation] = [:]
    private(set) var calls = 0
    private(set) var ordinaryCalls = 0
    private(set) var terminated: Set<Int> = []

    func open() -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        calls += 1
        let number = calls
        let pair = AsyncThrowingStream<LLMAssistantStreamEvent, Error>.makeStream()
        continuations[number] = pair.continuation
        pair.continuation.onTermination = { _ in
            Task { await self.didTerminate(number) }
        }
        if number == 1 { pair.continuation.yield(.textDelta("A partial 2780")) }
        return pair.stream
    }

    private func didTerminate(_ number: Int) { terminated.insert(number) }
    func unexpectedOrdinaryCall() { ordinaryCalls += 1 }

    func lateFirstDeltaWasRejected() -> Bool {
        guard let continuation = continuations[1] else { return false }
        // This is a real attempted late transport frame, after the actual
        // cancelled consumer has retired the stream, not a fabricated event.
        if case .terminated = continuation.yield(.textDelta("LATE-A-2780")) { return true }
        return false
    }

    func complete(_ number: Int, text: String) {
        guard let continuation = continuations.removeValue(forKey: number) else { return }
        continuation.yield(.textDelta(text))
        continuation.yield(.completed(LLMResponse(text: text, stopReason: "end_turn", usage: nil)))
        continuation.finish()
    }
}

private struct Turn2780Provider: AssistantStreamingLLMProvider, Sendable {
    let name = "Controlled2780"
    var model = LLMModel(id: "controlled2780", displayName: "Synthetic", provider: "Controlled2780")
    var capabilities: Set<ProviderCapability> { [.streaming] }
    let transport: Turn2780Transport

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        await transport.unexpectedOrdinaryCall()
        return LLMResponse(text: "unexpected ordinary call", stopReason: "end_turn", usage: nil)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await transport.unexpectedOrdinaryCall()
        throw LLMError.providerError(message: "unexpected text-only synthetic stream")
    }

    func streamAssistantMessage(messages: [LLMMessage], systemPrompt: String?,
                                tools: [AgentToolDefinition], maxTokens: Int,
                                temperature: Double?) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        await transport.open()
    }
}

@Suite("D-CONC3 production cancel, late frame, session switch and fresh-store resend")
@MainActor
struct ConcurrentTurnCancelSwitchRestart2780Tests {
    private func until(_ predicate: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<800 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }

    private func makeChat(profile: RuntimeIsolationProfile, store: SessionStore,
                          provider: Turn2780Provider, logName: String) throws -> ChatStore {
        let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(),
                             logManager: LogManager(directory: profile.rootDirectory.appendingPathComponent(logName)))
        try #require(chat.attachPersistence(store,
            badgeStore: SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges"))))
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "synthetic2780",
            grantEpoch: "synthetic2780-epoch", leaseID: "synthetic2780-lease",
            expiresAt: .distantFuture, autonomyCeiling: .l1)
        chat.configureComposerPolicy(facts)
        chat.agentEngine = AgentLoopChatEngine(composerPolicyFacts: facts)
        let skills = SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills"))
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(turn: turn,
                skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        chat.streamingProviderOverride = provider
        return chat
    }

    private func bytes(_ store: SessionStore, _ id: UUID) throws -> Data {
        try Data(contentsOf: store.sessionsDirectory.appendingPathComponent(id.uuidString + ".json"))
    }

    @Test func cancelledTurnCannotWriteAcrossSwitchOrFreshStoreAndNextTurnSucceeds() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "conc3-four-dimensions-2780", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        let transport = Turn2780Transport()
        let provider = Turn2780Provider(transport: transport)
        let store = SessionStore(directory: profile.sessionDirectory)
        let chat = try makeChat(profile: profile, store: store, provider: provider, logName: "first-logs")
        defer { chat.stopAllStreamingForSafety() }
        let sessionA = try #require(chat.activeSessionID)
        chat.draftText = "A user 2780"
        chat.submitComposer()
        try #require(await until { chat.messages.last?.content.contains("A partial 2780") == true })
        let executionA = try #require(chat.activeExecutionIdentity(for: sessionA))
        let turnA = try #require(chat.activeWritebackIdentity(for: sessionA))
        let assistantA = try #require(chat.messages.last?.id)
        let originalContentA = try #require(chat.messages.last?.content)
        chat.stopStreaming()
        #expect(chat.messages.last?.id == assistantA)
        #expect(chat.messages.last?.role == .assistant)
        #expect(chat.messages.last?.wasInterrupted == true)
        #expect(chat.messages.last?.content == originalContentA)
        let cancelled = try #require(chat.terminalReceipt(for: executionA))
        #expect(cancelled.outcome == .cancelled && cancelled.identity == executionA)
        try #require(await until { await transport.terminated.contains(1) })
        let stoppedA = try #require(store.loadSession(id: sessionA.uuidString))
        let stoppedBytesA = try bytes(store, sessionA)
        #expect(stoppedA.messages.last?.role == .assistant)
        #expect(stoppedA.messages.last?.content == originalContentA)

        chat.newSession()
        let sessionB = try #require(chat.activeSessionID)
        #expect(sessionB != sessionA)
        chat.draftText = "B user 2780"
        chat.submitComposer()
        try #require(await until { await transport.calls == 2 && chat.isActiveSessionStreaming })
        let executionB = try #require(chat.activeExecutionIdentity(for: sessionB))
        #expect(executionB.turn.sessionID == sessionB.uuidString)
        #expect(executionA.turn.sessionID == sessionA.uuidString)
        #expect(executionA.operationID != executionB.operationID)
        #expect(executionA.turn.messageID != executionB.turn.messageID)
        #expect(await transport.lateFirstDeltaWasRejected())
        // Also exercise the actual ChatStore immutable writeback boundary;
        // transport termination alone cannot prove this consumer predicate.
        #expect(!chat.updateMessageContent(sessionID: sessionA, messageID: assistantA,
                                          identity: turnA, append: "LATE-A-2780"))
        #expect(!chat.markExecutionSucceeded(sessionID: sessionA, executionIdentity: executionA))
        #expect(try bytes(store, sessionA) == stoppedBytesA)
        #expect(chat.activeSessionID == sessionB && chat.isActiveSessionStreaming)
        #expect(chat.messages.allSatisfy { !$0.content.contains("LATE-A-2780") })
        await transport.complete(2, text: "B complete 2780")
        try #require(await until { !chat.isActiveSessionStreaming && chat.messages.last?.content == "B complete 2780" })
        #expect(chat.terminalReceipt(for: executionB)?.outcome == .succeeded)
        #expect(chat.terminalReceipt(for: executionA) == cancelled)
        let completedB = try #require(store.loadSession(id: sessionB.uuidString))
        let completedBytesB = try bytes(store, sessionB)

        // A new canonical store plus a new ChatStore performs the actual
        // ordinary startup read/reconciliation; no memory transcript copy.
        let freshStore = SessionStore(directory: profile.sessionDirectory)
        let fresh = try makeChat(profile: profile, store: freshStore, provider: provider, logName: "fresh-logs")
        defer { fresh.stopAllStreamingForSafety() }
        #expect(try #require(freshStore.loadSession(id: sessionA.uuidString)).messages == stoppedA.messages)
        #expect(try #require(freshStore.loadSession(id: sessionB.uuidString)).messages == completedB.messages)
        #expect(fresh.sessions.flatMap(\.messages).allSatisfy { !$0.isStreaming && !$0.content.contains("LATE-A-2780") })
        #expect(!fresh.updateMessageContent(sessionID: sessionA, messageID: assistantA,
                                           identity: turnA, append: "LATE-A-2780"))
        #expect(!fresh.markExecutionSucceeded(sessionID: sessionA, executionIdentity: executionA))
        #expect(try bytes(freshStore, sessionA) == stoppedBytesA)
        #expect(try bytes(freshStore, sessionB) == completedBytesB)
        fresh.switchSession(id: sessionB)
        fresh.draftText = "C after reopen 2780"
        fresh.submitComposer()
        try #require(await until { await transport.calls == 3 && fresh.isActiveSessionStreaming })
        let executionC = try #require(fresh.activeExecutionIdentity(for: sessionB))
        #expect(executionC.operationID != executionB.operationID)
        #expect(executionC.turn.messageID != executionB.turn.messageID)
        // Repeat the old producer/consumer attempts while a fresh runtime's
        // legitimate new turn is live, not only while it has no active turn.
        #expect(await transport.lateFirstDeltaWasRejected())
        #expect(!fresh.updateMessageContent(sessionID: sessionA, messageID: assistantA,
                                           identity: turnA, append: "LATE-A-2780"))
        #expect(!fresh.markExecutionSucceeded(sessionID: sessionA, executionIdentity: executionA))
        #expect(fresh.activeSessionID == sessionB && fresh.isActiveSessionStreaming)
        #expect(fresh.messages.allSatisfy { !$0.content.contains("LATE-A-2780") })
        #expect(try bytes(freshStore, sessionA) == stoppedBytesA)
        await transport.complete(3, text: "C complete 2780")
        try #require(await until { !fresh.isActiveSessionStreaming && fresh.messages.last?.content == "C complete 2780" })
        #expect(fresh.terminalReceipt(for: executionC)?.outcome == .succeeded)
        let streamCalls = await transport.calls
        let ordinaryCalls = await transport.ordinaryCalls
        #expect(streamCalls == 3 && ordinaryCalls == 0)
        #expect(try bytes(freshStore, sessionA) == stoppedBytesA)
        let finalB = try #require(SessionStore(directory: profile.sessionDirectory).loadSession(id: sessionB.uuidString))
        #expect(Array(finalB.messages.suffix(4)).map(\.content)
            == ["B user 2780", "B complete 2780", "C after reopen 2780", "C complete 2780"])
    }
}
