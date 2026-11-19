import Foundation
import Testing
@testable import MinisCore

struct CanonicalProjectionCompactionTests {
    private final class RecordingProvider: LLMProvider, @unchecked Sendable {
        let name = "projection-recording-provider"
        var model = LLMModel(id: "projection-recording", displayName: "Projection", provider: "tests")
        var received: [[LLMMessage]] = []

        func sendMessage(messages: [LLMMessage], systemPrompt: String?,
                         maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
            received.append(messages)
            return LLMResponse(text: "Continued without replaying effects", stopReason: nil, usage: nil)
        }

        func streamMessage(messages: [LLMMessage], systemPrompt: String?,
                           maxTokens: Int, temperature: Double?) async throws
            -> AsyncThrowingStream<LLMStreamChunk, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private final class NoEffectExecutor: ToolExecutor, @unchecked Sendable {
        var calls = 0
        func execute(name: String, input: [String: Any]) async throws -> String {
            calls += 1
            return "unexpected effect"
        }
    }

    private func makeStore() throws -> (SessionStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "projection-compact-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (SessionStore(directory: root), root)
    }

    private func seed(_ store: SessionStore, id: String) throws -> ChatSession {
        _ = try store.createSession(id: id)
        for _ in 0..<40 {
            try store.saveMessage(LLMMessage(role: .user,
                content: "Repeated ordinary context with a retained exact constraint."),
                sessionID: id)
        }
        try store.saveMessage(LLMMessage(role: .user, content: "Current question"), sessionID: id)
        try store.saveMessage(LLMMessage(role: .assistant, content: "Current answer"), sessionID: id)
        return try #require(store.loadSession(id: id))
    }

    @Test func v2KeepsCanonicalTranscriptAndResumesReducedRequestAfterRestart() async throws {
        let (writer, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try seed(writer, id: "projection-roundtrip")
        let result = try await Compactor(keepRecentMessages: 2).compact(
            messages: source.messages, safetyMode: .requireVerbatimText
        )
        #expect(Compactor.hasMaterialRequestReduction(from: source.messages, to: result.messages))
        let checkpoint = try CompactionCheckpoint.makeProjection(
            sessionID: source.id, sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages, result: result, lineage: source.lineageIdentity
        )
        #expect(checkpoint.hasValidDigest)
        try writer.saveCompactionCheckpoint(checkpoint)
        #expect(writer.loadSession(id: source.id)?.messages == source.messages)
        let next = LLMMessage(role: .user, content: "Continue in this session")
        try writer.saveMessage(next, sessionID: source.id)

        let reader = SessionStore(directory: root)
        #expect(try reader.resumeMessages(sessionID: source.id) == result.messages + [next])
        #expect(reader.loadSession(id: source.id)?.messages == source.messages + [next])
        #expect(try reader.loadLatestCompactionCheckpoint(sessionID: source.id) == checkpoint)

        let provider = RecordingProvider()
        let effects = NoEffectExecutor()
        let loop = AgentLoop(maxIterations: 1, loopDetector: nil)
        _ = try await loop.run(
            messages: reader.resumeMessages(sessionID: source.id),
            systemPrompt: nil, provider: provider, toolExecutor: effects, tools: []
        )
        #expect(provider.received == [result.messages + [next]])
        #expect(effects.calls == 0)
    }

    @Test func v2RejectsUnverifiedOrForeignProjectionBeforeCommit() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try seed(store, id: "projection-source")
        let foreign = try store.createSession(id: "projection-foreign")
        let safe = try await Compactor(keepRecentMessages: 2).compact(
            messages: source.messages, safetyMode: .requireVerbatimText
        )
        let forged = CompactionResult(
            messages: [LLMMessage(role: .user,
                content: "<context-summary>omitted source</context-summary>")]
                + Array(source.messages.suffix(2)),
            summary: "omitted source", compactedCount: 40
        )
        #expect(throws: CompactionCheckpointError.invalidResult) {
            try CompactionCheckpoint.makeProjection(
                sessionID: source.id, sourceTranscriptRevision: source.transcriptRevision,
                sourceMessages: source.messages, result: forged
            )
        }
        let wrongSession = try CompactionCheckpoint.makeProjection(
            sessionID: foreign.id, sourceTranscriptRevision: foreign.transcriptRevision,
            sourceMessages: source.messages, result: safe, lineage: foreign.lineageIdentity
        )
        #expect(throws: SessionStoreError.compactionCheckpointBoundaryMismatch(wrongSession.checkpointID)) {
            try store.saveCompactionCheckpoint(wrongSession)
        }
        #expect(store.loadSession(id: source.id)?.messages == source.messages)
        #expect(store.loadSession(id: foreign.id)?.messages.isEmpty == true)
    }

    @Test func v2RejectsTamperedCheckpointWithoutReplacingOriginalHistory() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try seed(store, id: "projection-tamper")
        let result = try await Compactor(keepRecentMessages: 2).compact(
            messages: source.messages, safetyMode: .requireVerbatimText
        )
        let checkpoint = try CompactionCheckpoint.makeProjection(
            sessionID: source.id, sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages, result: result, lineage: source.lineageIdentity
        )
        try store.saveCompactionCheckpoint(checkpoint)
        let payloadURL = store.compactionCheckpointsDirectory
            .appendingPathComponent(checkpoint.checkpointID + ".json")
        var object = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: payloadURL)
        ) as? [String: Any])
        object["sourcePrefixDigest"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: object).write(to: payloadURL, options: .atomic)

        let reader = SessionStore(directory: root)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)) {
            try reader.resumeMessages(sessionID: source.id)
        }
        #expect(reader.loadSession(id: source.id)?.messages == source.messages)
    }

    @Test func secondManualCheckpointUsesFullCanonicalSourceWhileProjectedAutoSourceRefuses() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try seed(store, id: "projection-second")
        let compactor = Compactor(keepRecentMessages: 2)
        let first = try await compactor.compact(messages: original.messages,
            safetyMode: .requireVerbatimText)
        let firstCheckpoint = try CompactionCheckpoint.makeProjection(
            sessionID: original.id, sourceTranscriptRevision: original.transcriptRevision,
            sourceMessages: original.messages, result: first,
            lineage: original.lineageIdentity
        )
        try store.saveCompactionCheckpoint(firstCheckpoint)
        try store.saveMessage(LLMMessage(role: .user, content: "new turn question"),
            sessionID: original.id)
        try store.saveMessage(LLMMessage(role: .assistant, content: "new turn answer"),
            sessionID: original.id)

        let projectedSource = try store.resumeMessages(sessionID: original.id)
        let rejectedAuto = try await compactor.compact(messages: projectedSource,
            safetyMode: .requireVerbatimText)
        #expect(rejectedAuto.refusalReason == .unverifiableInformationLoss)
        #expect(rejectedAuto.messages == projectedSource)
        let canonical = try #require(store.loadSession(id: original.id))
        let second = try await compactor.compact(messages: canonical.messages,
            safetyMode: .requireVerbatimText)
        let secondCheckpoint = try CompactionCheckpoint.makeProjection(
            sessionID: canonical.id, sourceTranscriptRevision: canonical.transcriptRevision,
            sourceMessages: canonical.messages, result: second,
            lineage: canonical.lineageIdentity
        )
        try store.saveCompactionCheckpoint(secondCheckpoint)
        let reader = SessionStore(directory: root)
        #expect(try reader.resumeMessages(sessionID: original.id) == second.messages)
        #expect(reader.loadSession(id: original.id)?.messages == canonical.messages)
    }

    @Test func undoProjectionDoesNotResurrectEarlierCheckpointAfterRestart() async throws {
        let (writer, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try seed(writer, id: "projection-undo")
        let result = try await Compactor(keepRecentMessages: 2).compact(
            messages: source.messages, safetyMode: .requireVerbatimText
        )
        func publish() throws -> CompactionCheckpoint {
            let current = try #require(writer.loadSession(id: source.id))
            return try writer.saveCompactionCheckpoint(CompactionCheckpoint.makeProjection(
                sessionID: current.id, sourceTranscriptRevision: current.transcriptRevision,
                sourceMessages: current.messages, result: result, lineage: current.lineageIdentity
            ))
        }
        let first = try publish()
        let second = try publish()
        let current = try #require(writer.loadSession(id: source.id))
        #expect(throws: SessionStoreError.sessionSnapshotConflict(source.id)) {
            try writer.undoCompactionProjection(expectedSession: current, expectedCheckpoint: first)
        }
        try writer.undoCompactionProjection(expectedSession: current, expectedCheckpoint: second)

        let reader = SessionStore(directory: root)
        #expect(reader.loadSession(id: source.id) == current)
        #expect(try reader.loadLatestCompactionCheckpoint(sessionID: source.id) == nil)
        #expect(try reader.resumeMessages(sessionID: source.id) == source.messages)
        guard case .absent = try reader.compactionCheckpointAvailability(sessionID: source.id) else {
            Issue.record("An undone checkpoint should not be available or quarantined.")
            return
        }

        let third = try publish()
        #expect(try reader.loadLatestCompactionCheckpoint(sessionID: source.id) == third)
        let appended = LLMMessage(role: .user, content: "After the next compaction")
        try writer.saveMessage(appended, sessionID: source.id)
        let appendedSession = try #require(writer.loadSession(id: source.id))
        try writer.undoCompactionProjection(expectedSession: appendedSession, expectedCheckpoint: third)
        let reopened = SessionStore(directory: root)
        #expect(reopened.loadSession(id: source.id) == appendedSession)
        #expect(try reopened.resumeMessages(sessionID: source.id) == source.messages + [appended])
    }

    /// C-03：压缩后回退到压缩边界之前，下一回合续接不能再因检查点校验失败而报错。
    /// 回退时不处理检查点，这条会在 resumeMessages 抛错而红。
    @Test func rewindBeforeCompactionBoundaryKeepsResumeWorking() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "projection-rewind-past-checkpoint"
        _ = try store.createSession(id: id)
        try store.saveMessage(LLMMessage(role: .user, content: "Early question"), sessionID: id)
        try store.saveMessage(LLMMessage(role: .assistant, content: "Early answer"), sessionID: id)
        for _ in 0..<40 {
            try store.saveMessage(LLMMessage(role: .user,
                content: "Repeated ordinary context with a retained exact constraint."), sessionID: id)
        }
        try store.saveMessage(LLMMessage(role: .user, content: "Current question"), sessionID: id)
        try store.saveMessage(LLMMessage(role: .assistant, content: "Current answer"), sessionID: id)
        let source = try #require(store.loadSession(id: id))
        let result = try await Compactor(keepRecentMessages: 2).compact(
            messages: source.messages, safetyMode: .requireVerbatimText)
        try store.saveCompactionCheckpoint(CompactionCheckpoint.makeProjection(
            sessionID: source.id, sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages, result: result, lineage: source.lineageIdentity))
        #expect(try store.resumeMessages(sessionID: id) == result.messages)

        let anchor = try #require(try store.conversationRewindAnchors(sessionID: id)
            .first { $0.messageIndex == 1 })
        let committed = try store.rewindConversation(to: anchor)
        #expect(committed.messages.count == 2)

        let reader = SessionStore(directory: root)
        #expect(try reader.resumeMessages(sessionID: id) == committed.messages)
        try reader.saveMessage(LLMMessage(role: .user, content: "Next turn after rewind"), sessionID: id)
        #expect(try reader.resumeMessages(sessionID: id) == committed.messages
            + [LLMMessage(role: .user, content: "Next turn after rewind")])
    }

    /// MC4-009：链记录曾只增不减，单会话第 512 条前后新压缩被拒绝且没有出口。回退裁剪逻辑，这条会在约 511 次处抛错。
    @Test func compactionChainStaysUsableBeyondFiveHundredTwelveCheckpoints() async throws {
        let (writer, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try seed(writer, id: "projection-chain-cap")
        let result = try await Compactor(keepRecentMessages: 2).compact(
            messages: source.messages, safetyMode: .requireVerbatimText
        )
        var last: CompactionCheckpoint?
        for _ in 0..<520 {
            let current = try #require(writer.loadSession(id: source.id))
            last = try writer.saveCompactionCheckpoint(CompactionCheckpoint.makeProjection(
                sessionID: current.id, sourceTranscriptRevision: current.transcriptRevision,
                sourceMessages: current.messages, result: result, lineage: current.lineageIdentity
            ))
        }
        let latest = try #require(last)
        let chainFiles = try FileManager.default.contentsOfDirectory(
            at: writer.compactionCheckpointsDirectory, includingPropertiesForKeys: nil, options: []
        ).filter { $0.lastPathComponent.hasSuffix(".chain.json") }
        #expect(chainFiles.count <= SessionStore.checkpointChainPruneTrigger)

        // 重启后仍能读到最新检查点，并且撤销压缩（要求截止线记录仍在链里）可用。
        let reader = SessionStore(directory: root)
        #expect(try reader.loadLatestCompactionCheckpoint(sessionID: source.id) == latest)
        #expect(try reader.resumeMessages(sessionID: source.id) == result.messages)
        let current = try #require(reader.loadSession(id: source.id))
        try reader.undoCompactionProjection(expectedSession: current, expectedCheckpoint: latest)
        #expect(try SessionStore(directory: root).loadLatestCompactionCheckpoint(sessionID: source.id) == nil)
    }

    /// 裁剪不放宽完整性：裁剪后再有人删掉保留下来的最老一条链记录，读取仍要报需要恢复。
    @Test func prunedChainStillDetectsAMissingHeadRecord() async throws {
        let (writer, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try seed(writer, id: "projection-chain-head")
        let result = try await Compactor(keepRecentMessages: 2).compact(
            messages: source.messages, safetyMode: .requireVerbatimText
        )
        for _ in 0..<(SessionStore.checkpointChainPruneTrigger + 2) {
            let current = try #require(writer.loadSession(id: source.id))
            _ = try writer.saveCompactionCheckpoint(CompactionCheckpoint.makeProjection(
                sessionID: current.id, sourceTranscriptRevision: current.transcriptRevision,
                sourceMessages: current.messages, result: result, lineage: current.lineageIdentity
            ))
        }
        #expect(try SessionStore(directory: root).loadLatestCompactionCheckpoint(sessionID: source.id) != nil)
        let chainFiles = try FileManager.default.contentsOfDirectory(
            at: writer.compactionCheckpointsDirectory, includingPropertiesForKeys: nil, options: []
        ).filter { $0.lastPathComponent.hasSuffix(".chain.json") }
        #expect(chainFiles.count <= SessionStore.checkpointChainPruneTrigger)
        let revisions = try chainFiles.map { url -> (URL, Int) in
            let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            return (url, try #require(object["resultTranscriptRevision"] as? Int))
        }
        let oldest = try #require(revisions.min { $0.1 < $1.1 })
        try FileManager.default.removeItem(at: oldest.0)
        #expect(throws: SessionStoreError.self) {
            _ = try SessionStore(directory: root).loadLatestCompactionCheckpoint(sessionID: source.id)
        }
    }

}
