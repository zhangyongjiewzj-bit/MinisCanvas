import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Focused production-seam coverage for v383c.  These tests deliberately call
/// the app bridge used by both ChatStore manual compaction and AgentLoop's
/// automatic budget compaction; they do not duplicate SessionStore internals.
struct CanonicalCompactionCheckpointTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MinisCanvas-v383c-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func seed(
        _ store: SessionStore,
        id: String
    ) throws -> ChatSession {
        let session = try store.createSession(id: id)
        for index in 1...42 {
            try store.saveMessage(
                LLMMessage(
                    role: index == 42 ? .assistant : .user,
                    content: index <= 40
                        ? "Repeated ordinary conversation line with an exact retained constraint."
                        : "v383c-message-\(index)"
                ),
                sessionID: session.id
            )
        }
        return try #require(store.loadSession(id: session.id))
    }

    @Test func manualAndAutomaticConsumersShareCanonicalCheckpointBoundary() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let manualSession = try seed(store, id: "manual")
        let automaticSession = try seed(store, id: "automatic")
        let compactor = Compactor(keepRecentMessages: 2)

        let manualResult = try await compactor.compact(messages: manualSession.messages,
            safetyMode: .requireVerbatimText)
        let automaticResult = try await compactor.compact(messages: automaticSession.messages,
            safetyMode: .requireVerbatimText)
        let manual = try #require(
            try ChatSessionBridge.saveCanonicalCompactionCheckpoint(
                sessionStore: store,
                sessionID: manualSession.id,
                sourceMessages: manualSession.messages,
                expectedTranscriptRevision: manualSession.transcriptRevision,
                result: manualResult
            )
        )
        let automatic = try #require(
            try ChatSessionBridge.saveCanonicalCompactionCheckpoint(
                sessionStore: store,
                sessionID: automaticSession.id,
                sourceMessages: automaticSession.messages,
                expectedTranscriptRevision: automaticSession.transcriptRevision,
                result: automaticResult
            )
        )

        #expect(manual.replacementHistory == manualResult.messages)
        #expect(automatic.replacementHistory == automaticResult.messages)
        #expect(manual.schemaVersion == CompactionCheckpoint.projectionSchemaVersion)
        #expect(store.loadSession(id: manualSession.id)?.messages == manualSession.messages)
        #expect(store.loadSession(id: automaticSession.id)?.messages == automaticSession.messages)
        #expect(manual.lineageIdentity == manualSession.lineageIdentity)
        #expect(automatic.lineageIdentity == automaticSession.lineageIdentity)
        #expect(
            try ChatSessionBridge.resumeCanonicalMessages(
                sessionStore: store,
                sessionID: manualSession.id
            ) == manual.replacementHistory
        )
        #expect(
            try ChatSessionBridge.resumeCanonicalMessages(
                sessionStore: store,
                sessionID: automaticSession.id
            ) == automatic.replacementHistory
        )
    }

    @Test func literalSummaryMarkerInUserOrAssistantTextDoesNotBlockResume() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let session = try seed(store, id: "literal-marker")
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: session.messages,
            safetyMode: .requireVerbatimText)
        let checkpoint = try #require(
            try ChatSessionBridge.saveCanonicalCompactionCheckpoint(
                sessionStore: store, sessionID: session.id, sourceMessages: session.messages,
                expectedTranscriptRevision: session.transcriptRevision, result: result))
        try store.saveMessage(LLMMessage(role: .user, content: "<context-summary> 是什么意思？"),
                              sessionID: session.id)
        try store.saveMessage(LLMMessage(role: .assistant, content: "源码里写着 <context-summary> 字面量"),
                              sessionID: session.id)
        let resumed = try ChatSessionBridge.resumeCanonicalMessages(sessionStore: store, sessionID: session.id)
        #expect(resumed.count == checkpoint.replacementHistory.count + 2)
    }

    @Test func restartResumeDoesNotDuplicateCanonicalSummary() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = SessionStore(directory: directory)
        let session = try seed(writer, id: "restart")
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: session.messages,
            safetyMode: .requireVerbatimText)
        let checkpoint = try #require(
            try ChatSessionBridge.saveCanonicalCompactionCheckpoint(
                sessionStore: writer,
                sessionID: session.id,
                sourceMessages: session.messages,
                expectedTranscriptRevision: session.transcriptRevision,
                result: result
            )
        )
        try writer.saveMessage(
            LLMMessage(role: .user, content: "after-restart"),
            sessionID: session.id
        )

        let reader = SessionStore(directory: directory)
        let resumed = try ChatSessionBridge.resumeCanonicalMessages(
            sessionStore: reader,
            sessionID: session.id
        )
        #expect(resumed == checkpoint.replacementHistory + [
            LLMMessage(role: .user, content: "after-restart")
        ])
        #expect(resumed.filter { $0.content.contains("<context-summary>") }.count == 1)
        let resumedSession = try #require(reader.loadSession(id: session.id))
        #expect(resumedSession.id == session.id)
        #expect(resumedSession.transcriptRevision == checkpoint.resultTranscriptRevision + 1)
        #expect(resumedSession.messages == session.messages + [
            LLMMessage(role: .user, content: "after-restart")
        ])
        let secondFromCanonical = try await Compactor(keepRecentMessages: 2).compact(
            messages: resumedSession.messages, safetyMode: .requireVerbatimText
        )
        #expect(throws: SessionStoreError.compactionCheckpointBoundaryMismatch(session.id)) {
            try ChatSessionBridge.saveCanonicalCompactionCheckpoint(
                sessionStore: reader, sessionID: session.id,
                sourceMessages: resumed, result: secondFromCanonical
            )
        }
        #expect(reader.loadSession(id: session.id)?.messages == resumedSession.messages)
    }

    @Test func restartResumeRejectsDuplicateCanonicalSummary() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = SessionStore(directory: directory)
        let session = try seed(writer, id: "duplicate-summary")
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: session.messages,
            safetyMode: .requireVerbatimText)
        let checkpoint = try #require(
            try ChatSessionBridge.saveCanonicalCompactionCheckpoint(
                sessionStore: writer,
                sessionID: session.id,
                sourceMessages: session.messages,
                expectedTranscriptRevision: session.transcriptRevision,
                result: result
            )
        )
        try writer.saveMessage(checkpoint.summaryMessage, sessionID: session.id)

        let reader = SessionStore(directory: directory)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint(session.id)) {
            try ChatSessionBridge.resumeCanonicalMessages(
                sessionStore: reader,
                sessionID: session.id
            )
        }
    }

    @Test func staleAndCrossSessionSourcesFailClosedBeforeDurableWrite() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let session = try seed(store, id: "stale")
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: session.messages,
            safetyMode: .requireVerbatimText)

        try store.saveMessage(
            LLMMessage(role: .user, content: "newer"),
            sessionID: session.id
        )
        #expect(
            throws: SessionStoreError.compactionCheckpointRevisionMismatch(session.id)
        ) {
            try ChatSessionBridge.saveCanonicalCompactionCheckpoint(
                sessionStore: store,
                sessionID: session.id,
                sourceMessages: session.messages,
                expectedTranscriptRevision: session.transcriptRevision,
                result: result
            )
        }
        #expect(try store.loadLatestCompactionCheckpoint(sessionID: session.id) == nil)

        let other = try seed(store, id: "other")
        #expect(
            throws: SessionStoreError.compactionCheckpointBoundaryMismatch(session.id)
        ) {
            try ChatSessionBridge.saveCanonicalCompactionCheckpoint(
                sessionStore: store,
                sessionID: session.id,
                sourceMessages: other.messages,
                expectedTranscriptRevision: nil,
                result: result
            )
        }
        #expect(
            try ChatSessionBridge.resumeCanonicalMessages(
                sessionStore: store,
                sessionID: session.id
            ).last?.content == "newer"
        )
    }

    @Test func failedOrCancelledCompactionLeavesResumeTranscriptUntouched() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let session = try seed(store, id: "cancel")
        let unchanged = try ChatSessionBridge.saveCanonicalCompactionCheckpoint(
            sessionStore: store,
            sessionID: session.id,
            sourceMessages: session.messages,
            result: CompactionResult(
                messages: session.messages,
                summary: nil,
                compactedCount: 0
            )
        )
        #expect(unchanged == nil)
        #expect(
            try ChatSessionBridge.resumeCanonicalMessages(
                sessionStore: store,
                sessionID: session.id
            ) == session.messages
        )

        let cancelled = Task { () throws -> CompactionCheckpoint? in
            try Task.checkCancellation()
            return try ChatSessionBridge.saveCanonicalCompactionCheckpoint(
                sessionStore: store,
                sessionID: session.id,
                sourceMessages: session.messages,
                result: try await Compactor(keepRecentMessages: 2).compact(messages: session.messages,
                    safetyMode: .requireVerbatimText)
            )
        }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        #expect(try store.loadLatestCompactionCheckpoint(sessionID: session.id) == nil)
    }
}
