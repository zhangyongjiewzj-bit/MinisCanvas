import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class CompactionRefusalProvider2763: LLMProvider, @unchecked Sendable {
    let name = "compact-refusal-2763"
    var model = LLMModel(id: "compact-refusal-2763", displayName: "Fixture", provider: "test")
    private(set) var requests = 0

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        requests += 1
        return LLMResponse(text: "untrusted summary", stopReason: "stop", usage: nil)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        requests += 1
        return AsyncThrowingStream { $0.finish() }
    }
}

@Suite("D-H1C App attachment compaction summary", .serialized)
@MainActor
struct CompactionAttachmentRefusal2763Tests {
    /// Claude-Code-style compaction: an earlier image no longer blocks it. The
    /// model summarizes that message (the summary is lossy), while the canonical
    /// transcript and its image are kept untouched.
    @Test("the production ChatStore consumer summarizes an earlier image message and keeps the canonical image")
    func earlierAttachmentIsSummarizedAndCanonicalImageIsKept() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("compact-attachment-2763-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        let image = LLMMessage.ImageAttachment(mimeType: "image/png", data: Data([1, 2, 3]))
        let history = [
            LLMMessage(role: .user,
                       content: String(repeating: "Goal and constraint with an image that text cannot retain. ", count: 8),
                       images: [image]),
            LLMMessage(role: .assistant, content: "The earlier image remains part of the canonical history."),
            LLMMessage(role: .user, content: "Continue without losing that image.")
        ]
        let thread = ChatThread(id: id, messages: history.map { $0.asChatMessageUI() },
            transcriptRevision: UInt64(history.count))
        let store = SessionStore(directory: root)
        try store.updateSession(thread.asPersisted())
        try ChatAttachmentPersistence.save(sessions: [thread], to: root)
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        let before = try #require(chat.sessions.first(where: { $0.id == id }))
        #expect(before.messages.map { $0.asLLMMessage() } == history)
        let provider = CompactionRefusalProvider2763()

        // This is the App entry's actual consumer and notice path.
        await chat.runCompaction(history: before.messages, keepRecent: 1, sessionID: id,
            expectedTranscriptRevision: before.transcriptRevision,
            providerBox: LLMProviderBox(value: provider))

        #expect(provider.requests == 1)
        let checkpoint = try #require(try store.loadLatestCompactionCheckpoint(sessionID: id.uuidString))
        #expect(checkpoint.schemaVersion == CompactionCheckpoint.lossySummarySchemaVersion)
        #expect(checkpoint.replacementHistory.first?.content.contains("untrusted summary") == true)
        #expect(Array(checkpoint.replacementHistory.suffix(1)) == Array(history.suffix(1)))
        let after = try #require(chat.sessions.first(where: { $0.id == id }))
        #expect(after.messages.filter { $0.role != .system }.map { $0.asLLMMessage() } == history)
        #expect(!after.messages.contains { $0.role == .system && ($0.content.contains("已跳过压缩") || $0.content.hasPrefix("压缩失败")) })
        // The canonical transcript, image included, is not rewritten by a lossy summary.
        #expect(store.loadSession(id: id.uuidString)?.messages == history)
    }
}
