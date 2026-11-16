import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private struct NonReducingTimedChatSummaryProvider: LLMProvider {
    let name = "Nonreducing timed chat summary"
    var model = LLMModel(id: "timed-chat-summary", displayName: "Timed chat summary", provider: "test")
    let capabilities: Set<ProviderCapability> = []
    let summary: String

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        LLMResponse(text: summary, stopReason: "stop", usage: nil)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw LLMError.unsupportedCapability(.streaming)
    }
}

@Suite("Canonical timed Chat compaction")
@MainActor
struct CanonicalTimedChatCompactionTests {
    @Test func repeatedTimedChatKeepsFullHistoryAcrossRestartAndReducesModelView() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "timed-chat-compact-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var timing = ChatTurnTimingMetadata(startedAt: startedAt)
        timing.finishedAt = startedAt.addingTimeInterval(1)
        var history: [ChatMessageUI] = []
        for _ in 0..<20 {
            history.append(ChatMessageUI(role: .user,
                content: "Repeat this ordinary question while retaining its exact words."))
            history.append(ChatMessageUI(role: .assistant,
                content: "This is the ordinary answer, with its original turn timing.",
                turnTiming: timing, turnProviderName: "fixture provider", turnModelID: "fixture model"))
        }
        history.append(ChatMessageUI(role: .user, content: "Current question"))
        history.append(ChatMessageUI(role: .assistant, content: "Current answer"))
        let thread = ChatThread(id: id, messages: history, transcriptRevision: UInt64(history.count))
        let store = SessionStore(directory: root)
        try store.updateSession(thread.asPersisted())
        try ChatAttachmentPersistence.save(sessions: [thread], to: root)

        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        let facts = ComposerPolicyFactSource(
            knownCapabilities: ["file_write"], grantedCapabilities: [],
            allowedWriteRoots: [], workspaceID: chat.composerWorkspaceID,
            revision: "compact-policy-unchanged", grantEpoch: "compact-epoch",
            leaseID: "compact-lease", expiresAt: Date().addingTimeInterval(600)
        )
        chat.configureComposerPolicy(facts)
        let before = try #require(chat.sessions.first(where: { $0.id == id }))
        #expect(before.messages[1].turnTiming == timing)
        let changed = try await chat.performCompaction(
            history: before.messages, keepRecent: 2, sessionID: id,
            expectedTranscriptRevision: before.transcriptRevision,
            providerBox: LLMProviderBox(value: MockProvider.shared)
        )
        #expect(changed)
        let committed = try #require(store.loadSession(id: id.uuidString))
        #expect(committed.messages == before.messages.map { $0.asLLMMessage() })
        let after = try #require(chat.sessions.first(where: { $0.id == id }))
        #expect(after.messages == before.messages)
        #expect(after.messages[1].turnTiming == timing)
        #expect(after.transcriptRevision == before.transcriptRevision + 1)
        #expect(chat.composerPolicyFacts == facts)

        let restarted = ChatStore()
        #expect(restarted.attachPersistence(SessionStore(directory: root)))
        let restored = try #require(restarted.sessions.first(where: { $0.id == id }))
        #expect(restored.messages.map { $0.asLLMMessage() }
            == before.messages.map { $0.asLLMMessage() })
        #expect(restored.messages[1].turnTiming == timing)
        let modelView = try ChatSessionBridge.resumeCanonicalMessages(
            sessionStore: SessionStore(directory: root), sessionID: id.uuidString
        )
        #expect(modelView.first?.content.contains("<context-summary>") == true)
        #expect(Compactor.hasMaterialRequestReduction(
            from: committed.messages, to: modelView
        ))
    }

    @Test func projectionAdoptionPreservesInFlightAndRejectsConcurrentAppendOrRevision() throws {
        let chat = ChatStore()
        let id = try #require(chat.activeSessionID)
        let source = [ChatMessageUI(role: .user, content: "original question")]
        let streaming = ChatMessageUI(role: .assistant, content: "partial answer", isStreaming: true)
        #expect(chat.setMessages(source + [streaming], forSession: id))
        let revision = try #require(chat.transcriptRevision(forSession: id))
        let committed = ChatThread(id: id, messages: source,
            transcriptRevision: revision + 1).asPersisted()

        #expect(!chat.adoptProjectionCompaction(committed,
            sourceHistory: source, inFlightAssistant: streaming,
            expectedUIRevision: revision + 1))
        #expect(chat.messages(forSession: id) == source + [streaming])
        #expect(chat.adoptProjectionCompaction(committed,
            sourceHistory: source, inFlightAssistant: streaming,
            expectedUIRevision: revision))
        #expect(chat.messages(forSession: id) == source + [streaming])
        #expect(chat.transcriptRevision(forSession: id) == revision + 1)

        let appended = ChatMessageUI(role: .user, content: "concurrent new turn")
        #expect(chat.setMessages(source + [streaming, appended], forSession: id))
        let appendedRevision = try #require(chat.transcriptRevision(forSession: id))
        #expect(!chat.adoptProjectionCompaction(committed,
            sourceHistory: source, inFlightAssistant: streaming,
            expectedUIRevision: appendedRevision))
        #expect(chat.messages(forSession: id) == source + [streaming, appended])
    }

    @Test func variedTimedChatDoesNotCreateAnIneffectiveCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "varied-timed-chat-compact-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var history: [ChatMessageUI] = []
        for index in 0..<12 {
            history.append(ChatMessageUI(role: .user,
                content: "Question \(index): decide how this unique paragraph changes the next step."))
            var timing = ChatTurnTimingMetadata(startedAt: base.addingTimeInterval(Double(index * 4)))
            timing.finishedAt = base.addingTimeInterval(Double(index * 4 + 2))
            history.append(ChatMessageUI(role: .assistant,
                content: "Answer \(index): this response records a distinct observation for that question.",
                turnTiming: timing, turnProviderName: "fixture provider", turnModelID: "fixture model"))
        }
        let thread = ChatThread(id: id, messages: history,
            transcriptRevision: UInt64(history.count))
        let store = SessionStore(directory: root)
        try store.updateSession(thread.asPersisted())
        try ChatAttachmentPersistence.save(sessions: [thread], to: root)
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        let before = try #require(chat.sessions.first(where: { $0.id == id }))
        let olderTranscript = before.messages.dropLast(2).map(\.content).joined(separator: "\n")
        // A model can return a verbose recap instead of reducing the request.
        let provider = NonReducingTimedChatSummaryProvider(
            summary: olderTranscript + "\n\n" + olderTranscript
        )
        var refused = false
        do {
            _ = try await chat.performCompaction(history: before.messages,
                keepRecent: 2, sessionID: id,
                expectedTranscriptRevision: before.transcriptRevision,
                providerBox: LLMProviderBox(value: provider))
        } catch ChatCompactionSafetyError.noMeaningfulReduction {
            refused = true
        }
        #expect(refused)
        #expect(try store.loadLatestCompactionCheckpoint(sessionID: id.uuidString) == nil)
        #expect(store.loadSession(id: id.uuidString)?.messages
            == before.messages.map { $0.asLLMMessage() })
        #expect(chat.sessions.first(where: { $0.id == id })?.messages == before.messages)
    }
}
