import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// A synthetic transport only: ChatStore, its immutable turn snapshots, the
/// AgentLoopChatEngine fallback, cancellation and terminal receipts are real.
private final class Chat07TwoTurnProvider: AssistantStreamingLLMProvider, @unchecked Sendable {
    let name = "Chat07Synthetic"
    var model = LLMModel(id: "chat07-synthetic", displayName: "Chat07", provider: "Chat07Synthetic")
    var capabilities: Set<ProviderCapability> { [.streaming] }

    private let lock = NSLock()
    private var streamCalls = 0
    private var ordinaryCalls = 0
    private var firstTerminated = false
    private var userInputs: [String] = []
    private var lifecycleEvents: [String] = []
    private var secondContinuation: AsyncThrowingStream<LLMAssistantStreamEvent, Error>.Continuation?
    var observed: (streams: Int, ordinary: Int, firstTerminated: Bool, users: [String], events: [String]) {
        lock.withLock { (streamCalls, ordinaryCalls, firstTerminated, userInputs, lifecycleEvents) }
    }

    func completeSecond() {
        let continuation = lock.withLock { () -> AsyncThrowingStream<LLMAssistantStreamEvent, Error>.Continuation? in
            defer { secondContinuation = nil }
            if secondContinuation != nil { lifecycleEvents.append("second.completed") }
            return secondContinuation
        }
        continuation?.yield(.textDelta("第二回合完整输出"))
        continuation?.yield(.completed(LLMResponse(
            text: "第二回合完整输出", stopReason: "end_turn", usage: nil
        )))
        continuation?.finish()
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { ordinaryCalls += 1 }
        return LLMResponse(text: "unexpected non-streaming response", stopReason: "end_turn", usage: nil)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?,
                     tools: [AgentToolDefinition], maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        lock.withLock { ordinaryCalls += 1 }
        throw LLMError.providerError(message: "unexpected text-only synthetic stream")
    }

    func streamAssistantMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        let number = lock.withLock { () -> Int in
            streamCalls += 1
            userInputs.append(messages.last(where: { $0.role == .user })?.content ?? "")
            lifecycleEvents.append("request.\(streamCalls).started")
            return streamCalls
        }
        return AsyncThrowingStream { continuation in
            if number == 1 {
                continuation.yield(.textDelta("第一回合部分输出"))
                // The production task must cancel this still-open stream.
                continuation.onTermination = { [weak self] termination in
                    guard let self else { return }
                    self.lock.withLock {
                        self.firstTerminated = true
                        if case .cancelled = termination {
                            self.lifecycleEvents.append("first.cancelled")
                        }
                    }
                }
            } else {
                lock.withLock { secondContinuation = continuation }
            }
        }
    }
}

@Suite("D-CHAT-07 production two-turn stop and resend")
@MainActor
struct DChat07ProductionTwoTurnStop2769Tests {
    private func until(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<800 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func stoppedStreamingProviderTurnCannotCompleteAndNextDraftStartsFreshRequest() async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("chat07-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let defaults = try #require(UserDefaults(suiteName: "chat07-\(UUID().uuidString)"))
        let chat = ChatStore(preferencesDefaults: defaults,
                             logManager: LogManager(directory: root.appendingPathComponent("logs")))
        #expect(chat.attachPersistence(SessionStore(directory: root),
            badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        let sessionID = try #require(chat.activeSessionID)
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "chat07-policy",
            grantEpoch: "chat07-epoch", leaseID: "chat07-lease",
            expiresAt: .distantFuture, autonomyCeiling: .l1
        )
        chat.configureComposerPolicy(facts)
        chat.agentEngine = AgentLoopChatEngine(composerPolicyFacts: facts)
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(turn: turn,
                skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        let provider = Chat07TwoTurnProvider()
        chat.streamingProviderOverride = provider

        chat.draftText = "第一条"
        chat.submitComposer()
        #expect(await until {
            provider.observed.streams == 1 &&
                chat.messages.last?.content.contains("第一回合部分输出") == true
        })
        let firstIdentity = try #require(chat.activeExecutionIdentity(for: sessionID))
        let firstUserID = try #require(chat.messages.last(where: { $0.role == .user })?.id)
        let firstWriteback = try #require(chat.activeWritebackIdentity(for: sessionID))
        let firstAssistantID = try #require(UUID(uuidString: firstWriteback.messageID))
        // Execution retains the submitted user message; writeback owns the
        // separate assistant bubble for that same session and turn.
        #expect(firstIdentity.turn.messageID == firstUserID.uuidString)
        #expect(firstWriteback.sessionID == firstIdentity.turn.sessionID)
        #expect(firstWriteback.turnID == firstIdentity.turn.turnID)
        #expect(chat.messages.last?.id == firstAssistantID)
        #expect(chat.isActiveSessionStreaming)

        chat.stopStreaming()
        let firstTerminal = try #require(chat.terminalReceipt(for: firstIdentity))
        #expect(firstTerminal.outcome == .cancelled)
        #expect(!chat.isActiveSessionStreaming)
        #expect(await until { provider.observed.firstTerminated })
        let stoppedMessage = try #require(chat.messages.first(where: { $0.id == firstAssistantID }))
        #expect(stoppedMessage.wasInterrupted)
        #expect(stoppedMessage.content == "第一回合部分输出")
        #expect(ChatTranscriptFormatter.formattedMessage(stoppedMessage, baseSize: 14, redactor: nil)
            .string.contains("已中断"))

        chat.draftText = "第二条"
        chat.submitComposer()
        #expect(await until { provider.observed.streams == 2 && chat.isActiveSessionStreaming })
        let secondIdentity = try #require(chat.activeExecutionIdentity(for: sessionID))
        let secondWriteback = try #require(chat.activeWritebackIdentity(for: sessionID))
        let secondAssistantID = try #require(UUID(uuidString: secondWriteback.messageID))
        #expect(secondWriteback.sessionID == secondIdentity.turn.sessionID)
        #expect(secondWriteback.turnID == secondIdentity.turn.turnID)
        #expect(chat.messages.last?.id == secondAssistantID)
        provider.completeSecond()
        #expect(await until {
            !chat.isActiveSessionStreaming &&
                chat.messages.last?.content.contains("第二回合完整输出") == true
        })
        let secondTerminal = try #require(chat.terminalReceipt(for: secondIdentity))
        let secondUserID = try #require(chat.messages.last(where: { $0.role == .user })?.id)
        #expect(secondIdentity.turn.messageID == secondUserID.uuidString)

        #expect(secondTerminal.outcome == .succeeded)
        #expect(chat.terminalReceipt(for: firstIdentity)?.outcome == .cancelled)
        #expect(firstIdentity != secondIdentity)
        #expect(firstIdentity.turn.sessionID == secondIdentity.turn.sessionID)
        #expect(firstIdentity.turn.turnID != secondIdentity.turn.turnID)
        #expect(firstIdentity.operationID != secondIdentity.operationID)
        #expect(firstTerminal.identity == firstIdentity && secondTerminal.identity == secondIdentity)
        #expect(firstUserID != secondUserID && firstAssistantID != secondAssistantID)
        #expect(provider.observed.streams == 2 && provider.observed.ordinary == 0)
        #expect(provider.observed.users == ["第一条", "第二条"])
        #expect(provider.observed.events == [
            "request.1.started", "first.cancelled", "request.2.started", "second.completed"
        ])
        #expect(chat.messages.first(where: { $0.id == firstAssistantID })?.content.contains("第二回合完整输出") == false)
        let rawTrace = [
            "first=\(firstIdentity.operationID)",
            "firstUser=\(firstUserID.uuidString)",
            "firstAssistant=\(firstAssistantID.uuidString)",
            "firstOutcome=\(firstTerminal.outcome)",
            "second=\(secondIdentity.operationID)",
            "secondUser=\(secondUserID.uuidString)",
            "secondAssistant=\(secondAssistantID.uuidString)",
            "secondOutcome=\(secondTerminal.outcome)",
            "providerEvents=\(provider.observed.events.joined(separator: ","))"
        ]
        print("DCHAT07_TWO_TURNS " + rawTrace.joined(separator: " "))
    }
}
