import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private enum SendSnapshotFixtureError: Error {
    case unexpectedLegacyEntry
}

private struct SendSnapshotProvider: LLMProvider, Sendable {
    let name: String
    var model: LLMModel

    init(name: String, modelID: String) {
        self.name = name
        model = LLMModel(
            id: modelID, displayName: modelID, provider: name,
            modalityOverride: .vision
        )
    }

    nonisolated(nonsending) func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "synthetic", stopReason: "end_turn", usage: nil)
    }

    nonisolated(nonsending) func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}

@MainActor
private final class SendSnapshotRecordingEngine: ChatAgentEngine {
    struct Capture {
        let conversationID: String?
        let providerName: String
        let modelID: String
        let history: [ChatMessageUI]
        let composerSnapshot: ComposerSubmissionSnapshot
        let executionIdentity: AgentExecutionIdentity
    }

    nonisolated var isAvailable: Bool { true }
    private(set) var captures: [Capture] = []

    nonisolated(nonsending) func streamReply(
        provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        throw SendSnapshotFixtureError.unexpectedLegacyEntry
    }

    func streamReply(
        provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, maxTokens: Int, conversationID: String?,
        authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?, turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot,
        executionIdentity: AgentExecutionIdentity
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        captures.append(Capture(
            conversationID: conversationID,
            providerName: provider.name,
            modelID: provider.model.id,
            history: history,
            composerSnapshot: composerSnapshot,
            executionIdentity: executionIdentity
        ))
        return AsyncThrowingStream { continuation in
            continuation.yield(.done(stopReason: .endTurn))
            continuation.finish()
        }
    }

    nonisolated func interrupt() {}

    nonisolated(nonsending) func compactContext(
        provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, keepRecent: Int
    ) async -> CompactionResult {
        CompactionResult(messages: [], summary: nil, compactedCount: 0)
    }
}

private actor HeldComposer12Preparation {
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { pending.append($0) }
    }
    func isPending() -> Bool { !pending.isEmpty }
    func finish() {
        released = true
        let waiting = pending
        pending.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

@Suite("D-COMPOSER-12 send-boundary session snapshot", .serialized)
@MainActor
struct P3AcceptanceM02_SendSnapshotIsolationTests {
    @Test("an immediate session switch cannot move the sent body, media, or model")
    func immediateSwitchKeepsOriginalTurnTogether() async throws {
        let suite = "M02-send-snapshot-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: logDirectory)
        }

        let chat = ChatStore(
            preferencesDefaults: defaults,
            logManager: LogManager(directory: logDirectory)
        )
        defer { chat.stopAllStreamingForSafety() }
        let engine = SendSnapshotRecordingEngine()
        chat.agentEngine = engine
        chat.streamingProviderOverride = SendSnapshotProvider(name: "Provider A", modelID: "model-a")

        let originalSessionID = try #require(chat.activeSessionID)
        let imageBytes = try ComposerMediaFixtures589.png()
        #expect(MediaPayloadValidation.failure(data: imageBytes, mimeType: "image/png") == nil)
        let image = ChatAttachment(
            kind: .image, fileName: "synthetic.png", fileType: .image,
            mimeType: "image/png", size: Int64(imageBytes.count), data: imageBytes
        )
        chat.draftText = "仅属于 A 的正文"
        chat.addComposerDraftAttachment(image)
        chat.submitComposer()
        let originalSent = try #require(chat.sessions.first(where: { $0.id == originalSessionID })?
            .messages.last(where: { $0.role == .user }))

        // Do not yield between send and switch: the old engine task has not
        // acquired an opportunity to reread mutable active-session controls.
        let secondSessionID = chat.applyNewSession(title: "B")
        chat.streamingProviderOverride = SendSnapshotProvider(name: "Provider B", modelID: "model-b")
        chat.draftText = "仅属于 B 的正文"
        chat.submitComposer()

        for _ in 0..<100 where engine.captures.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(engine.captures.count == 2)
        let originalCapture = try #require(engine.captures.first {
            $0.composerSnapshot.sessionID == originalSessionID.uuidString
        })
        let secondCapture = try #require(engine.captures.first {
            $0.composerSnapshot.sessionID == secondSessionID.uuidString
        })
        let originalRequest = try #require(originalCapture.history.last(where: { $0.role == .user }))
        let secondRequest = try #require(secondCapture.history.last(where: { $0.role == .user }))

        #expect(originalCapture.conversationID == originalSessionID.uuidString)
        #expect(originalCapture.composerSnapshot.messageID == originalSent.id.uuidString)
        #expect(originalCapture.providerName == "Provider A")
        #expect(originalCapture.modelID == "model-a")
        #expect(originalRequest.id == originalSent.id)
        #expect(originalRequest.content.contains("仅属于 A 的正文"))
        #expect(originalRequest.attachments.first?.id == image.id)
        #expect(originalRequest.asLLMMessage().images.first?.data == imageBytes)

        #expect(secondCapture.conversationID == secondSessionID.uuidString)
        #expect(secondCapture.providerName == "Provider B")
        #expect(secondCapture.modelID == "model-b")
        #expect(secondRequest.content.contains("仅属于 B 的正文"))
        #expect(!secondRequest.content.contains("仅属于 A 的正文"))
        #expect(secondRequest.attachments.isEmpty)
        #expect(secondRequest.asLLMMessage().images.isEmpty)
        #expect(secondCapture.history.allSatisfy { !$0.content.contains("仅属于 A 的正文") })

        let originalThread = try #require(chat.sessions.first { $0.id == originalSessionID })
        let secondThread = try #require(chat.sessions.first { $0.id == secondSessionID })
        #expect(originalThread.messages.first(where: { $0.id == originalSent.id })?.attachments.first?.id == image.id)
        #expect(originalThread.messages.first(where: { $0.id == originalSent.id })?.content.contains("仅属于 A 的正文") == true)
        #expect(secondThread.messages.allSatisfy { !$0.content.contains("仅属于 A 的正文") })
        #expect(secondThread.messages.allSatisfy { $0.attachments.isEmpty })
        #expect(originalThread.messages.first(where: { $0.turnModelID != nil })?.turnModelID == "model-a")
        #expect(secondThread.messages.first(where: { $0.turnModelID != nil })?.turnModelID == "model-b")
        #expect(chat.activeSessionID == secondSessionID)
    }
    @Test("selected Provider and cold credential sends retain the original committed turn across A to B", arguments: [false, true])
    func selectedProviderSwitchKeepsOriginalTurn(coldCredential: Bool) async throws {
        let suite = "M02-selected-snapshot-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let chat = ChatStore(preferencesDefaults: defaults, logManager: LogManager(directory: directory))
        defer { chat.stopAllStreamingForSafety() }
        let engine = SendSnapshotRecordingEngine()
        chat.agentEngine = engine
        let recordA = EnvVarEntry(
            name: "LUNA", value: coldCredential ? "" : "owned-fixture-key",
            isSecret: true, valueInKeychain: coldCredential,
            baseURL: "https://example.invalid", modelNames: ["gpt-4o"],
            protocolType: .openaiCompatible
        )
        let recordB = EnvVarEntry(
            name: "SYNTHETIC_COMPOSER12_B", value: "owned-fixture-key",
            isSecret: true, valueInKeychain: false,
            baseURL: "https://example.invalid", modelNames: ["gpt-4o-mini"],
            protocolType: .openaiCompatible
        )
        var publishedA = recordA
        #expect(EnvCredentials.canonicalName(recordA.name) == recordA.name)
        #expect(EnvCredentials.canonicalName(recordB.name) == recordB.name)
        chat.providerRecordsSource = { [publishedA, recordB] }
        chat.schedulerCredentialVersionSource = { _ in "owned-revision" }
        chat.selectedCustomProvider = recordA
        chat.selectedModelID = "gpt-4o"
        let held = HeldComposer12Preparation()
        if coldCredential {
            chat.providerCredentialPreflightSource = { id, name, revision in
                #expect(id == recordA.id && name == recordA.name && revision == "owned-revision")
                publishedA.value = "owned-fixture-key"
                return true
            }
        }
        chat.providerConstructionPauseForTests = { await held.wait() }
        let originalID = try #require(chat.activeSessionID)
        chat.appendUser("A 原历史")
        let bytes = try ComposerMediaFixtures589.png()
        let image = ChatAttachment(
            kind: .image, fileName: "synthetic.png", fileType: .image,
            mimeType: "image/png", size: Int64(bytes.count), data: bytes
        )
        chat.draftText = "A 冻结正文"
        chat.addComposerDraftAttachment(image)
        #expect(chat.composerMediaReadinessSnapshot.attachment(id: image.id)?.readiness == .supported)
        #expect(chat.composerAttachmentBlockReason == nil)
        chat.submitComposer()
        let sent = try #require(chat.messages.last { $0.role == .user })
        let frozen = try #require(chat.lastComposerSubmissionSnapshot)
        #expect(chat.draftText.isEmpty)
        #expect(chat.pendingAttachments.isEmpty)
        #expect(frozen.messageID == sent.id.uuidString)
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await held.isPending()) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard await held.isPending() else {
            await held.finish()
            Issue.record("selected Provider worker did not reach owned pause")
            return
        }
        if coldCredential { #expect(publishedA.value == "owned-fixture-key") }
        let secondID = chat.applyNewSession(title: "B")
        chat.selectedCustomProvider = recordB
        chat.selectedModelID = "gpt-4o-mini"
        chat.draftText = "B 独立正文"
        chat.submitComposer()
        await held.finish()
        while engine.captures.count < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(engine.captures.count == 2)
        let a = try #require(engine.captures.first { $0.composerSnapshot.sessionID == originalID.uuidString })
        let b = try #require(engine.captures.first { $0.composerSnapshot.sessionID == secondID.uuidString })
        #expect(a.composerSnapshot == frozen)
        #expect(a.executionIdentity.turn.sessionID == frozen.sessionID)
        #expect(a.executionIdentity.turn.turnID == frozen.turnID)
        #expect(a.executionIdentity.turn.messageID == frozen.messageID)
        #expect(a.executionIdentity.attempt == 1)
        #expect(a.conversationID == originalID.uuidString)
        #expect(a.providerName == recordA.name && a.modelID == "gpt-4o")
        #expect(a.history.contains { $0.content == "A 原历史" })
        #expect(a.history.allSatisfy { !$0.content.contains("B 独立正文") })
        let aRequest = try #require(a.history.last { $0.role == .user })
        #expect(aRequest.id == sent.id && aRequest.content.contains("A 冻结正文"))
        #expect(aRequest.attachments.first?.id == image.id)
        #expect(aRequest.asLLMMessage().images.first?.data == bytes)
        #expect(b.providerName == recordB.name && b.modelID == "gpt-4o-mini")
        #expect(b.history.last?.content == "B 独立正文")
        #expect(b.history.allSatisfy { !$0.content.contains("A 冻结正文") && !$0.content.contains("A 原历史") })
        #expect(b.history.allSatisfy { $0.attachments.isEmpty })
        let aThread = try #require(chat.sessions.first { $0.id == originalID })
        #expect(aThread.messages.filter { $0.id == sent.id }.count == 1)
        #expect(aThread.messages.first { $0.id == sent.id }?.attachments.first?.id == image.id)
        #expect(aThread.messages.first { $0.turnModelID != nil }?.turnModelID == "gpt-4o")
        #expect(chat.activeSessionID == secondID)
        #expect(chat.messages.allSatisfy { !$0.content.contains("A 冻结正文") && $0.attachments.isEmpty })
    }

}
