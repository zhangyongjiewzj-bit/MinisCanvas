import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private enum SyntheticMediaDeliveryError: Error {
    case rejected
}

@MainActor
private final class MediaHistoryRecordingEngine: ChatAgentEngine {
    nonisolated var isAvailable: Bool { false }
    var capturedHistories: [[ChatMessageUI]] = []
    var failNext = true

    nonisolated(nonsending) func streamReply(
        provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        throw SyntheticMediaDeliveryError.rejected
    }

    func streamReply(
        provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, maxTokens: Int, conversationID: String?,
        authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?, turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot,
        executionIdentity: AgentExecutionIdentity
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        capturedHistories.append(history)
        if failNext {
            failNext = false
            throw SyntheticMediaDeliveryError.rejected
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("合成成功"))
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

@MainActor
struct P3AcceptanceM02_MediaFailureIsolationTests {
    private func makeChat(withSource: Bool = true) throws -> (ChatStore, MediaHistoryRecordingEngine, UUID) {
        let suite = "M02-media-isolation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let chat = ChatStore(
            preferencesDefaults: defaults,
            logManager: LogManager(directory: logDirectory)
        )
        let engine = MediaHistoryRecordingEngine()
        chat.agentEngine = engine
        chat.streamingProviderOverride = MockProvider.shared
        let sessionID = chat.activeSessionID!
        let png = try ComposerMediaFixtures589.png()
        let source = logDirectory.appendingPathComponent("synthetic.png")
        if withSource { try png.write(to: source) }
        let image = ChatAttachment(
            kind: .image, fileName: "synthetic.png", fileType: .image,
            mimeType: "image/png", data: png, fileURL: withSource ? source.path : nil
        )
        chat.addComposerDraftAttachment(image)
        chat.draftText = "请看图片"
        return (chat, engine, sessionID)
    }

    private func awaitIdle(_ chat: ChatStore) async throws {
        for _ in 0..<200 {
            if !chat.isActiveSessionStreaming { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("合成回合未在有界窗口内终止")
    }

    @Test func failedImageDoesNotReplayIntoLaterTextTurn() async throws {
        let (chat, engine, sessionID) = try makeChat()
        chat.submitComposer()
        try await awaitIdle(chat)

        let original = try #require(chat.messages.last(where: { $0.role == .user }))
        let media = try #require(original.attachments.first)
        #expect(media.deliveryQuarantined == true)
        #expect(media.data == (try ComposerMediaFixtures589.png()))
        #expect(engine.capturedHistories.count == 1)
        #expect(engine.capturedHistories[0].last?.asLLMMessage().images.count == 1)

        chat.draftText = "后续纯文本"
        chat.submitComposer()
        try await awaitIdle(chat)

        #expect(engine.capturedHistories.count == 2)
        let later = try #require(engine.capturedHistories.last)
        let old = try #require(later.first(where: { $0.id == original.id }))
        #expect(old.attachments.isEmpty)
        #expect(old.asLLMMessage().images.isEmpty)
        #expect(old.content.contains("此前媒体附件未完成发送"))
        #expect(!old.content.contains("已随消息附加，请查看"))
        #expect(chat.messages.first(where: { $0.id == original.id })?.attachments.first?.id == media.id)
        #expect(chat.messages.first(where: { $0.id == original.id })?.attachments.first?.deliveryQuarantined == true)
        #expect(chat.activeSessionID == sessionID)
    }

    @Test func explicitRetryUsesSameMediaIdentityAndClearsQuarantineOnSuccess() async throws {
        let (chat, engine, sessionID) = try makeChat()
        chat.submitComposer()
        try await awaitIdle(chat)
        let original = try #require(chat.messages.last(where: { $0.role == .user }))
        let mediaID = try #require(original.attachments.first?.id)
        let retry = try #require(chat.executionSnapshot(forSessionID: sessionID)?.retryIdentity)

        #expect(chat.retryFailedSession(retry))
        try await awaitIdle(chat)

        #expect(engine.capturedHistories.count == 2)
        let retried = try #require(engine.capturedHistories.last?.first(where: { $0.id == original.id }))
        #expect(retried.attachments.first?.id == mediaID)
        #expect(retried.asLLMMessage().images.count == 1)
        #expect(chat.messages.first(where: { $0.id == original.id })?.attachments.first?.deliveryQuarantined == nil)
        #expect(chat.messages.filter { $0.role == .user }.count == 1)
    }

    @Test("failed source attachment can be explicitly removed or referenced in a new draft",
          arguments: [false, true])
    func failedMediaUserActionPreparesSafeReplacement(asFileReference: Bool) async throws {
        let (chat, engine, _) = try makeChat()
        chat.submitComposer()
        try await awaitIdle(chat)
        let failedTurn = try #require(chat.messages.last(where: { $0.role == .user }))
        let failedMedia = try #require(failedTurn.attachments.first)
        #expect(failedMedia.deliveryQuarantined == true)
        #expect(!chat.prepareFailedMediaDraft(
            messageID: failedTurn.id, attachmentID: UUID(), asFileReference: asFileReference
        ))

        #expect(chat.prepareFailedMediaDraft(
            messageID: failedTurn.id, attachmentID: failedMedia.id,
            asFileReference: asFileReference
        ))
        #expect(chat.isEditingMessage && chat.draftText == "请看图片")
        let prepared = chat.pendingAttachments
        if asFileReference {
            let reference = try #require(prepared.first)
            #expect(prepared.count == 1 && reference.id != failedMedia.id)
            #expect(reference.kind == .file && reference.fileType == .unknown)
            #expect(reference.data == nil && reference.fileURL == failedMedia.fileURL)
            #expect(chat.composerMediaReadinessSnapshot.attachment(id: reference.id)?.readiness == .referenceOnly)
        } else {
            #expect(prepared.isEmpty)
        }
        #expect(chat.messages.first(where: { $0.id == failedTurn.id }) == failedTurn)

        chat.submitComposer()
        try await awaitIdle(chat)
        #expect(engine.capturedHistories.count == 2)
        let later = try #require(engine.capturedHistories.last)
        let old = try #require(later.first(where: { $0.id == failedTurn.id }))
        #expect(old.attachments.isEmpty && old.asLLMMessage().images.isEmpty)
        let replacement = try #require(later.last(where: { $0.role == .user }))
        #expect(replacement.id != failedTurn.id && replacement.asLLMMessage().images.isEmpty)
        #expect(replacement.attachments.count == (asFileReference ? 1 : 0))
        #expect(replacement.content.contains("路径 " + (failedMedia.fileURL ?? "<missing>")) == asFileReference)
        #expect(chat.messages.first(where: { $0.id == failedTurn.id }) == failedTurn)
    }

    @Test("failed saved media without original path materializes a file reference only on user action")
    func failedMediaWithoutSourceCanBecomeFileReference() async throws {
        let (chat, _, _) = try makeChat(withSource: false)
        chat.submitComposer()
        try await awaitIdle(chat)
        let failedTurn = try #require(chat.messages.last(where: { $0.role == .user }))
        let failedMedia = try #require(failedTurn.attachments.first)
        #expect(failedMedia.deliveryQuarantined == true)
        #expect(ChatAttachmentOpenTarget.sourceState(for: failedMedia) == .missingSourceMaterializable)
        #expect(chat.prepareFailedMediaDraft(
            messageID: failedTurn.id, attachmentID: failedMedia.id, asFileReference: true
        ))
        let reference = try #require(chat.pendingAttachments.first)
        #expect(reference.kind == .file && reference.data == nil)
        #expect(reference.id != failedMedia.id)
        let materializedPath = try #require(reference.fileURL)
        #expect(FileManager.default.fileExists(atPath: materializedPath))
        #expect(chat.messages.first(where: { $0.id == failedTurn.id }) == failedTurn)
    }

    @Test func legacyAttachmentDecodesWithoutFabricatingFailure() throws {
        let attachment = ChatAttachment(
            kind: .image, fileName: "legacy.png", fileType: .image,
            mimeType: "image/png", data: Data([1, 2, 3])
        )
        var value = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(attachment)) as? [String: Any])
        value.removeValue(forKey: "deliveryQuarantined")
        let legacy = try JSONSerialization.data(withJSONObject: value)
        #expect(try JSONDecoder().decode(ChatAttachment.self, from: legacy).deliveryQuarantined == nil)
    }
}
