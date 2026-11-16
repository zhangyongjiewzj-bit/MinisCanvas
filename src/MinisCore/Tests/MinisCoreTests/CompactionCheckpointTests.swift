import Foundation
import Testing
@testable import MinisCore

struct CompactionCheckpointTests {
    private final class CancellationAwareProvider: LLMProvider, @unchecked Sendable {
        var name: String { "CancellationAwareCompactor" }
        var model = LLMModel(id: "cancel-compactor", displayName: "Cancel Compactor", provider: "Tests")
        let onSend: @Sendable () -> Void

        init(onSend: @escaping @Sendable () -> Void) {
            self.onSend = onSend
        }

        func sendMessage(
            messages: [LLMMessage],
            systemPrompt: String?,
            maxTokens: Int,
            temperature: Double?
        ) async throws -> LLMResponse {
            onSend()
            try await Task.sleep(for: .seconds(60))
            return LLMResponse(
                text: "unexpected summary",
                stopReason: nil,
                usage: nil
            )
        }

        func streamMessage(
            messages: [LLMMessage],
            systemPrompt: String?,
            maxTokens: Int,
            temperature: Double?
        ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
            AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCore-CompactionCheckpoint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func seed(
        _ store: SessionStore,
        id: String = "checkpoint-session"
    ) throws -> ChatSession {
        let session = try store.createSession(id: id)
        for index in 1...4 {
            try store.saveMessage(
                LLMMessage(role: index.isMultiple(of: 2) ? .assistant : .user, content: "message-\(index)"),
                sessionID: session.id
            )
        }
        return try #require(store.loadSession(id: session.id))
    }

    @Test func sameCheckpointIDDifferentPayloadIsRejected() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let session = try seed(store)
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: session.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: session.id,
            sourceTranscriptRevision: session.transcriptRevision,
            sourceMessages: session.messages,
            result: result,
            checkpointID: "same-id",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        _ = try store.saveCompactionCheckpoint(checkpoint)
        let committedSession = try #require(store.loadSession(id: session.id))
        let checkpointURL = store.compactionCheckpointsDirectory
            .appendingPathComponent(checkpoint.checkpointID + ".json")
        let chainURL = store.compactionCheckpointsDirectory
            .appendingPathComponent("." + checkpoint.checkpointID + ".chain.json")
        let checkpointBytes = try Data(contentsOf: checkpointURL)
        let chainBytes = try Data(contentsOf: chainURL)
        let checkpointDirectoryNames = try FileManager.default.contentsOfDirectory(
            at: store.compactionCheckpointsDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ).map(\.lastPathComponent).sorted()

        let changed = try CompactionCheckpoint.make(
            sessionID: session.id,
            sourceTranscriptRevision: session.transcriptRevision,
            sourceMessages: session.messages,
            result: CompactionResult(
                messages: [
                    LLMMessage(role: .user, content: "<context-summary>changed</context-summary>"),
                    session.messages[2],
                    session.messages[3]
                ],
                summary: "changed",
                compactedCount: 2
            ),
            checkpointID: "same-id",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        #expect(throws: SessionStoreError.compactionCheckpointConflict("same-id")) {
            try store.saveCompactionCheckpoint(changed)
        }
        #expect(store.loadSession(id: session.id) == committedSession)
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
        #expect(try Data(contentsOf: chainURL) == chainBytes)
        #expect(try FileManager.default.contentsOfDirectory(
            at: store.compactionCheckpointsDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ).map(\.lastPathComponent).sorted() == checkpointDirectoryNames)
    }

    @Test func duplicateCheckpointIsIdempotentAndRestartDoesNotDuplicateSummary() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = SessionStore(directory: directory)
        let session = try seed(writer)
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: session.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: session.id,
            sourceTranscriptRevision: session.transcriptRevision,
            sourceMessages: session.messages,
            result: result,
            checkpointID: "idempotent",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        #expect(try writer.saveCompactionCheckpoint(checkpoint) == checkpoint)
        #expect(try writer.saveCompactionCheckpoint(checkpoint) == checkpoint)

        try writer.saveMessage(
            LLMMessage(role: .user, content: "tail-after-compact"),
            sessionID: session.id
        )
        let reader = SessionStore(directory: directory)
        let resumed = try reader.resumeMessages(sessionID: session.id)
        #expect(resumed == result.messages + [
            LLMMessage(role: .user, content: "tail-after-compact")
        ])
        #expect(resumed.filter { $0.content.contains("<context-summary>") }.count == 1)
        let resumedSession = try #require(reader.loadSession(id: session.id))
        #expect(resumedSession.id == session.id)
        #expect(resumedSession.transcriptRevision == checkpoint.resultTranscriptRevision + 1)
    }

    @Test func duplicateRevisionCheckpointsFailClosedWithoutReplayingEitherHistory() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = SessionStore(directory: directory)
        let session = try seed(writer, id: "duplicate-revision")
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: session.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: session.id,
            sourceTranscriptRevision: session.transcriptRevision,
            sourceMessages: session.messages,
            result: result,
            checkpointID: "duplicate-revision-primary",
            createdAt: Date(timeIntervalSince1970: 8)
        )
        try writer.saveCompactionCheckpoint(checkpoint)

        let duplicate = CompactionCheckpoint(
            schemaVersion: checkpoint.schemaVersion,
            checkpointID: "duplicate-revision-secondary",
            sessionID: checkpoint.sessionID,
            sourceTranscriptRevision: checkpoint.sourceTranscriptRevision,
            resultTranscriptRevision: checkpoint.resultTranscriptRevision,
            compactedThroughMessageID: checkpoint.compactedThroughMessageID,
            compactedMessageRange: checkpoint.compactedMessageRange,
            summaryMessage: checkpoint.summaryMessage,
            replacementHistory: checkpoint.replacementHistory,
            lineage: checkpoint.lineage,
            contentDigest: "",
            createdAt: Date(timeIntervalSince1970: 9)
        ).withDigest()
        let duplicatePath = writer.compactionCheckpointsDirectory
            .appendingPathComponent("duplicate-revision-secondary.json")
        try JSONEncoder().encode(duplicate).write(to: duplicatePath, options: .atomic)

        let reader = SessionStore(directory: directory)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(duplicate.checkpointID)) {
            try reader.resumeMessages(sessionID: session.id)
        }
        let unchanged = try #require(reader.loadSession(id: session.id))
        #expect(unchanged.id == session.id)
        #expect(unchanged.transcriptRevision == checkpoint.resultTranscriptRevision)
        #expect(unchanged.messages == checkpoint.replacementHistory)
        #expect(FileManager.default.fileExists(atPath: duplicatePath.path))
    }

    @Test func legacySessionWithoutCheckpointStillResumes() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let session = try store.createSession(id: "legacy")
        try store.saveMessage(LLMMessage(role: .user, content: "legacy message"), sessionID: session.id)
        #expect(try store.resumeMessages(sessionID: session.id).count == 1)
        #expect(try store.loadLatestCompactionCheckpoint(sessionID: session.id) == nil)
    }

    @Test func storeCompactSessionUsesCanonicalCompactorPath() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = SessionStore(directory: directory)
        let session = try seed(writer)
        let checkpoint = try #require(
            await writer.compactSession(
                sessionID: session.id,
                using: Compactor(keepRecentMessages: 2)
            )
        )
        #expect(checkpoint.sessionID == session.id)
        #expect(checkpoint.sourceTranscriptRevision == 4)
        #expect(checkpoint.resultTranscriptRevision == 5)

        let reader = SessionStore(directory: directory)
        #expect(try reader.resumeMessages(sessionID: session.id) == checkpoint.replacementHistory)
    }

    @Test func staleRevisionAndCrossSessionBoundaryAreRejected() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let session = try seed(store)
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: session.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: session.id,
            sourceTranscriptRevision: session.transcriptRevision,
            sourceMessages: session.messages,
            result: result,
            checkpointID: "stale",
            createdAt: Date(timeIntervalSince1970: 3)
        )
        try store.saveMessage(LLMMessage(role: .user, content: "newer"), sessionID: session.id)
        #expect(throws: SessionStoreError.compactionCheckpointRevisionMismatch("stale")) {
            try store.saveCompactionCheckpoint(checkpoint)
        }
        let unchanged = try #require(store.loadSession(id: session.id))
        #expect(unchanged.id == session.id)
        #expect(unchanged.transcriptRevision == checkpoint.sourceTranscriptRevision + 1)

        let other = try store.createSession(id: "other")
        try store.saveMessage(LLMMessage(role: .user, content: "other-message"), sessionID: other.id)
        let foreign = try CompactionCheckpoint.make(
            sessionID: session.id,
            sourceTranscriptRevision: try #require(store.loadSession(id: session.id)?.transcriptRevision),
            sourceMessages: [LLMMessage(role: .user, content: "other-message")],
            result: try await Compactor(keepRecentMessages: 0).compact(
                messages: [LLMMessage(role: .user, content: "other-message")]
            ),
            checkpointID: "foreign",
            createdAt: Date(timeIntervalSince1970: 4)
        )
        #expect(throws: SessionStoreError.compactionCheckpointBoundaryMismatch("foreign")) {
            try store.saveCompactionCheckpoint(foreign)
        }
    }

    @Test func corruptedCheckpointFailsClosedAfterRestart() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = SessionStore(directory: directory)
        let session = try seed(writer)
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: session.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: session.id,
            sourceTranscriptRevision: session.transcriptRevision,
            sourceMessages: session.messages,
            result: result,
            checkpointID: "corrupt",
            createdAt: Date(timeIntervalSince1970: 5)
        )
        try writer.saveCompactionCheckpoint(checkpoint)
        let path = writer.compactionCheckpointsDirectory.appendingPathComponent("corrupt.json")
        try Data(
            #"{"schemaVersion":1,"sessionID":"checkpoint-session"}"#.utf8
        ).write(to: path, options: .atomic)

        let reader = SessionStore(directory: directory)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint("corrupt")) {
            try reader.resumeMessages(sessionID: session.id)
        }
        let unchanged = try #require(reader.loadSession(id: session.id))
        #expect(unchanged.id == session.id)
        #expect(unchanged.transcriptRevision == checkpoint.resultTranscriptRevision)
        #expect(unchanged.messages == checkpoint.replacementHistory)
        #expect(FileManager.default.fileExists(atPath: path.path) == false)
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: reader.compactionCheckpointsQuarantineDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        #expect(quarantined.count == 1)
    }

    @Test func truncatedCheckpointFailsClosedAndQuarantinesWithoutDuplicateReplay() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = SessionStore(directory: directory)
        let session = try seed(writer)
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: session.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: session.id,
            sourceTranscriptRevision: session.transcriptRevision,
            sourceMessages: session.messages,
            result: result,
            checkpointID: "truncated",
            createdAt: Date(timeIntervalSince1970: 6)
        )
        try writer.saveCompactionCheckpoint(checkpoint)

        let path = writer.compactionCheckpointsDirectory
            .appendingPathComponent("truncated.json")
        try Data(#"{"schemaVersion":1,"sessionID":"checkpoint-session""#.utf8)
            .write(to: path, options: .atomic)

        let reader = SessionStore(directory: directory)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint("truncated")) {
            try reader.resumeMessages(sessionID: session.id)
        }
        #expect(FileManager.default.fileExists(atPath: path.path) == false)

        let quarantined = try FileManager.default.contentsOfDirectory(
            at: reader.compactionCheckpointsQuarantineDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        #expect(quarantined.count == 1)

        let resumedAfterQuarantine = try reader.resumeMessages(sessionID: session.id)
        #expect(resumedAfterQuarantine == checkpoint.replacementHistory)
        #expect(
            resumedAfterQuarantine.filter { $0.content.contains("<context-summary>") }.count == 1
        )
    }

    @Test func futureCheckpointSchemaFailsClosedWithoutRewritingSession() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = SessionStore(directory: directory)
        let session = try seed(writer)
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: session.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: session.id,
            sourceTranscriptRevision: session.transcriptRevision,
            sourceMessages: session.messages,
            result: result,
            checkpointID: "future-schema",
            createdAt: Date(timeIntervalSince1970: 7)
        )
        try writer.saveCompactionCheckpoint(checkpoint)

        let checkpointPath = writer.compactionCheckpointsDirectory
            .appendingPathComponent("future-schema.json")
        var futurePayload = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: checkpointPath)
            ) as? [String: Any]
        )
        futurePayload["schemaVersion"] = 2
        let futureData = try JSONSerialization.data(
            withJSONObject: futurePayload,
            options: [.sortedKeys]
        )
        try futureData.write(to: checkpointPath, options: .atomic)

        let sessionPath = directory
            .appendingPathComponent("sessions/\(session.id).json")
        let sessionBefore = try Data(contentsOf: sessionPath)
        let reader = SessionStore(directory: directory)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint("future-schema")) {
            try reader.resumeMessages(sessionID: session.id)
        }
        #expect(FileManager.default.fileExists(atPath: checkpointPath.path) == false)
        #expect(try Data(contentsOf: sessionPath) == sessionBefore)

        let quarantined = try FileManager.default.contentsOfDirectory(
            at: reader.compactionCheckpointsQuarantineDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        #expect(quarantined.count == 1)
        #expect(try Data(contentsOf: quarantined[0]) == futureData)
    }

    @Test func canonicalCheckpointRejectsRevisionOverflowAndNonCanonicalSummary() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let session = try seed(store, id: "canonical-shape")
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: session.messages)

        #expect(throws: CompactionCheckpointError.invalidResult) {
            try CompactionCheckpoint.make(
                sessionID: session.id,
                sourceTranscriptRevision: UInt64.max,
                sourceMessages: session.messages,
                result: result
            )
        }
        #expect(throws: CompactionCheckpointError.invalidResult) {
            try CompactionCheckpoint.make(
                sessionID: session.id,
                sourceTranscriptRevision: UInt64.max - 1,
                sourceMessages: session.messages,
                result: result
            )
        }
        #expect(throws: CompactionCheckpointError.invalidResult) {
            try CompactionCheckpoint.make(
                sessionID: session.id,
                sourceTranscriptRevision: session.transcriptRevision,
                sourceMessages: session.messages,
                result: result,
                checkpointID: "../escape"
            )
        }

        let malformedResult = CompactionResult(
            messages: [
                LLMMessage(
                    role: .assistant,
                    content: Compactor.summaryEnvelope("assistant summary")
                ),
                session.messages[2],
                session.messages[3]
            ],
            summary: "assistant summary",
            compactedCount: 2
        )
        #expect(throws: CompactionCheckpointError.invalidResult) {
            try CompactionCheckpoint.make(
                sessionID: session.id,
                sourceTranscriptRevision: session.transcriptRevision,
                sourceMessages: session.messages,
                result: malformedResult
            )
        }
    }

    @Test func corruptCheckpointForOtherSessionDoesNotBlockOrQuarantineTarget() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        _ = try store.createSession(id: "session-a")
        let sessionB = try seed(store, id: "session-b")
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: sessionB.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: sessionB.id,
            sourceTranscriptRevision: sessionB.transcriptRevision,
            sourceMessages: sessionB.messages,
            result: result,
            checkpointID: "session-b-checkpoint"
        )
        try store.saveCompactionCheckpoint(checkpoint)

        let corruptAURL = store.compactionCheckpointsDirectory
            .appendingPathComponent("session-a-corrupt.json")
        try Data(
            #"{"schemaVersion":1,"sessionID":"session-a","checkpointID":"session-a-corrupt"}"#.utf8
        ).write(to: corruptAURL, options: .atomic)

        let reader = SessionStore(directory: directory)
        #expect(try reader.loadLatestCompactionCheckpoint(sessionID: "session-b") == checkpoint)
        #expect(FileManager.default.fileExists(atPath: corruptAURL.path))
        #expect(
            FileManager.default.fileExists(
                atPath: reader.compactionCheckpointsQuarantineDirectory.path
            ) == false
        )

        #expect(throws: SessionStoreError.invalidCompactionCheckpoint("session-a-corrupt")) {
            try reader.loadLatestCompactionCheckpoint(sessionID: "session-a")
        }
        #expect(FileManager.default.fileExists(atPath: corruptAURL.path) == false)
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: reader.compactionCheckpointsQuarantineDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        #expect(quarantined.count == 1)
    }

    @Test func cancelledCompactionDoesNotPersistCheckpoint() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let session = try seed(store)
        let (providerStarted, providerStartedContinuation) = AsyncStream<Void>.makeStream()
        let provider = CancellationAwareProvider {
            providerStartedContinuation.yield(())
        }
        let task = Task {
            try await store.compactSession(
                sessionID: session.id,
                using: Compactor(keepRecentMessages: 1),
                summarizeUsing: provider,
                safetyMode: .legacySummarization
            )
        }

        let startTimeout = Task {
            try? await Task.sleep(for: .seconds(2))
            providerStartedContinuation.finish()
        }
        var startEvents = providerStarted.makeAsyncIterator()
        let didStart = await startEvents.next() != nil
        startTimeout.cancel()
        task.cancel()
        try #require(didStart, "compaction never reached the cancellable provider")
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(try store.loadLatestCompactionCheckpoint(sessionID: session.id) == nil)
        #expect(store.loadSession(id: session.id)?.messages == session.messages)
    }
}
