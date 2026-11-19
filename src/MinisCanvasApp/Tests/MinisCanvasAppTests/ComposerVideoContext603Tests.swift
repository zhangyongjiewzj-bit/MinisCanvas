import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("Video603 Composer audio/subtitle and durable payload consumer")
@MainActor
struct ComposerVideoContext603Tests {
    private var fixture: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("MinisCore/Tests/MinisCoreTests/Fixtures/video603-av-caption.mp4")
    }
    private func resolved() async throws -> ChatAttachment {
        await ChatStore.resolveVideoAttachment(id: UUID(), url: fixture, name: "owned603.mp4",
            mime: "video/mp4", size: 7127, source: try AVFoundationVideoFrameSource(fileURL: fixture))
    }
    private func provider(_ modalities: ModelModality) -> any LLMProvider {
        let model = LLMModel(id: "video603", displayName: "Owned", provider: "Synthetic", modalityOverride: modalities)
        let placeholder = "[configured locally]"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Video603NoNetworkProtocol.self]
        return OpenAICompatibleProvider(apiKey: placeholder, model: model,
            customBaseURL: "https://video603.invalid", session: URLSession(configuration: configuration))
    }

    @Test func actualVideoContextFeedsImagesWAVAndIndexedSubtitleText() async throws {
        let video = try await resolved()
        #expect(video.status == .ready)
        #expect(video.videoContext?.audioState == .extracted)
        #expect(video.videoContext?.subtitleState == .extracted)
        let content = ChatStore.composeUserContent(text: "owned extraction", attachments: [video])
        #expect(content.contains("[内嵌字幕 00:00.100–00:00.800]"))
        #expect(content.contains("owned cue 一"))
        #expect(content.contains("[本地音轨"))
        #expect(!content.contains(fixture.path))
        let message = ChatMessageUI(role: .user, content: content, attachments: [video])
        let request = message.asLLMMessage()
        #expect(request.images.count == 3)
        let audio = try #require(request.audios.first)
        #expect(request.audios.count == 1)
        #expect(audio.format == "wav")
        #expect(Data(base64Encoded: audio.base64Data) == video.videoContext?.audio?.data)
        let caps = ModelCapabilities(supportedModalities: .fullMultimodalInput, supportedAuth: [.apiKey])
        let parts = try #require(OpenAICompatibleProvider.openAIMessageDict(request, mediaCapabilities: caps)["content"] as? [[String: Any]])
        #expect(parts.filter { $0["type"] as? String == "image_url" }.count == 3)
        #expect(parts.filter { $0["type"] as? String == "input_audio" }.count == 1)
        #expect(parts.contains { ($0["text"] as? String)?.contains("owned cue 一") == true })
    }

    // 11/16 起视频随所选模型自动调整：模型能收图片但不能收音频时，去掉音轨只发画面，草稿不再被拦下。
    @Test func compoundReadinessRechecksAudioCapabilityAndDropsAudioTrackForVisionModel() async throws {
        Video603NoNetworkProtocol.reset()
        let video = try await resolved()
        let chat = ChatStore()
        defer { chat.stopAllStreamingForSafety() }
        chat.streamingProviderOverride = provider(.fullMultimodalInput)
        chat.addComposerDraftAttachment(video); chat.draftText = "owned compound draft"
        let full = chat.composerMediaReadinessSnapshot
        #expect(full.attachment(id: video.id)?.readiness == .supported)
        #expect(full.attachment(id: video.id)?.requiredInputModalities.contains(.audioInput) == true)
        #expect(chat.canSubmitComposerAttachments)
        chat.streamingProviderOverride = provider(.vision)
        #expect(!chat.isCurrentComposerMediaReadiness(full))
        let vision = chat.composerMediaReadinessSnapshot.attachment(id: video.id)
        #expect(vision?.readiness == .supported)
        #expect(vision?.requiredInputModalities.contains(.audioInput) == false)
        #expect(vision?.reason.contains("未附带音轨") == true)
        #expect(chat.canSubmitComposerAttachments)
        #expect(chat.draftText == "owned compound draft")
        #expect(Video603NoNetworkProtocol.count == 0)
    }

    @Test func restartBindsExactAudioSlotAndRejectsChangedSubtitleOrAudio() async throws {
        let video = try await resolved()
        let composed = ChatStore.composeUserContentWithOwnership(text: "owned restart", attachments: [video])
        let content = composed.content
        let thread = ChatThread(messages: [.init(role: .user, content: content,
            attachments: [video], composedContentOwnership: composed.ownership)])
        let persisted = thread.asPersisted()
        let record = try #require(ChatAttachmentPersistence.records(for: thread).messages.first)
        #expect(record.attachments.first?.videoContext?.audio?.data == nil)
        #expect(record.attachments.first?.videoFrames?.allSatisfy { $0.pngData == nil } == true)
        let reopened = ChatAttachmentPersistence.restoreAttachments(from: persisted, records: [record])
        #expect(reopened.messages[0].asLLMMessage().audios.map(\.base64Data) == persisted.messages[0].audios.map(\.base64Data))
        #expect(reopened.messages[0].asLLMMessage().audios.map(\.format) == persisted.messages[0].audios.map(\.format))
        #expect(reopened.messages[0].asLLMMessage().images.map(\.data) == persisted.messages[0].images.map(\.data))
        #expect(reopened.messages[0].asLLMMessage().images.map(\.mimeType) == persisted.messages[0].images.map(\.mimeType))
        #expect(reopened.messages[0].attachments[0].videoContext?.subtitles == video.videoContext?.subtitles)
        var wrongAudio = persisted
        wrongAudio.messages[0].audios[0] = .init(format: "wav", base64Data: Data("wrong owned slot".utf8).base64EncodedString())
        let rejected = ChatAttachmentPersistence.restoreAttachments(from: wrongAudio, records: [record])
        #expect(rejected.messages[0].attachments[0].status == .failed)
        #expect(rejected.messages[0].asLLMMessage().audios.isEmpty)
        #expect(rejected.messages[0].asLLMMessage().images.isEmpty)
        let metadata = try #require(record.attachments[0].videoContext)
        let forged = MediaVideoSupplementaryContext(durationSeconds: metadata.durationSeconds,
            audioState: metadata.audioState, subtitleState: .extracted, audio: metadata.audio,
            subtitles: [.init(startSeconds: 0.1, endSeconds: 0.8, text: "forged owned subtitle")])
        let alteredAttachment = ChatAttachment(id: video.id, kind: .file, fileName: video.fileName,
            fileType: .video, mimeType: video.mimeType, size: video.size, fileURL: video.fileURL,
            videoFrames: record.attachments[0].videoFrames, videoContext: forged)
        let altered = ChatAttachmentPersistence.MessageRecord(messageIndex: record.messageIndex,
            contentDigest: record.contentDigest, attachments: [alteredAttachment],
            composedContentOwnership: record.composedContentOwnership,
            referenceCard: record.referenceCard, trustedSessionReadIntent: record.trustedSessionReadIntent,
            turnTiming: record.turnTiming, sessionReferenceCard: record.sessionReferenceCard)
        let subtitleRejected = ChatAttachmentPersistence.restoreAttachments(from: persisted, records: [altered])
        #expect(subtitleRejected.messages[0].attachments[0].status == .failed)
        #expect(subtitleRejected.messages[0].asLLMMessage().audios.isEmpty)
    }
}

// Even a failed admission assertion cannot make this negative fixture use DNS
// or a real provider: all requests terminate in this local URLProtocol.
private final class Video603NoNetworkProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests = 0
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    static func reset() { lock.lock(); requests = 0; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
    override func stopLoading() {}
}
