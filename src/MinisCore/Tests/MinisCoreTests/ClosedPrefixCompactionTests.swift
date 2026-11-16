import Foundation
import Testing
@testable import MinisCore

@Suite("Canonical closed-prefix compaction", .serialized)
struct ClosedPrefixCompactionTests {
    private final class SummaryProvider: LLMProvider, @unchecked Sendable {
        let name = "closed-prefix"
        var model = LLMModel(id: "closed-prefix", displayName: "Test", provider: "test")
        func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                         temperature: Double?) async throws -> LLMResponse {
            .init(text: "The assistant compared distinct alternatives and recorded their costs.",
                  stopReason: "stop", usage: nil)
        }
        func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                           temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private func fixture() throws -> (SessionStore, ChatSession, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("closed-prefix-\(UUID())")
        let store = SessionStore(directory: root)
        let session = try store.createSession(id: "closed-prefix")
        try store.saveMessage(.init(role: .user, content: "Keep the exact goal and constraints."), sessionID: session.id)
        for index in 0..<8 {
            try store.saveMessage(.init(role: .assistant, content: (0..<30).map {
                "Alternative \(index), cost \($0 + index * 19), dependency \(index - $0), and distinct fallback \($0)."
            }.joined(separator: " ")), sessionID: session.id)
        }
        try store.saveMessage(.init(role: .user, content: "Continue safely."), sessionID: session.id)
        try store.saveMessage(.init(role: .assistant, content: "mutable partial"), sessionID: session.id)
        return (store, try #require(store.loadSession(id: session.id)), root)
    }

    @Test func fullWriterStillRejectsPrefixButCASWriterKeepsMutableSuffixAcrossRestart() async throws {
        let (store, source, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let closed = Array(source.messages.dropLast())
        let result = try await Compactor(keepRecentMessages: 1).compact(messages: closed,
            summarizeUsing: SummaryProvider(), safetyMode: .sourceAnchoredNatural)
        let checkpoint = try CompactionCheckpoint.makeProjection(sessionID: source.id,
            sourceTranscriptRevision: source.transcriptRevision, sourceMessages: closed,
            result: result, lineage: source.lineageIdentity)
        #expect(throws: SessionStoreError.self) { try store.saveCompactionCheckpoint(checkpoint) }
        #expect(store.loadSession(id: source.id) == source)
        let saved = try #require(try store.compareAndSaveCompactionPrefix(expectedSession: source,
            closedPrefixCount: closed.count, result: result))
        var finalized = try #require(store.loadSession(id: source.id))
        #expect(finalized.messages == source.messages)
        finalized.messages[finalized.messages.count - 1] = .init(role: .assistant, content: "final answer")
        finalized.transcriptRevision += 1
        try store.updateSession(finalized)
        let restarted = SessionStore(directory: root)
        #expect(try restarted.loadLatestCompactionCheckpoint(sessionID: source.id) == saved)
        #expect(try restarted.resumeMessages(sessionID: source.id)
            == result.messages + [.init(role: .assistant, content: "final answer")])
        #expect(restarted.loadSession(id: source.id)?.messages == finalized.messages)
    }

    @Test func CASRejectsSameRevisionChangedLiveSuffixAndForeignSnapshot() async throws {
        let (store, source, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await Compactor(keepRecentMessages: 1).compact(messages: Array(source.messages.dropLast()),
            summarizeUsing: SummaryProvider(), safetyMode: .sourceAnchoredNatural)
        var changed = source
        changed.messages[changed.messages.count - 1] = .init(role: .assistant, content: "changed without revision")
        try store.updateSession(changed)
        #expect(throws: SessionStoreError.self) {
            try store.compareAndSaveCompactionPrefix(expectedSession: source,
                closedPrefixCount: source.messages.count - 1, result: result)
        }
        var foreign = changed
        foreign.projectID = "foreign-project"
        #expect(throws: SessionStoreError.self) {
            try store.compareAndSaveCompactionPrefix(expectedSession: foreign,
                closedPrefixCount: source.messages.count - 1, result: result)
        }
        #expect(try store.loadLatestCompactionCheckpoint(sessionID: source.id) == nil)
        #expect(store.loadSession(id: source.id) == changed)
    }
}
