import CoreGraphics
import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private struct M02ReadinessProvider: LLMProvider, Sendable {
    let name = "Synthetic readiness"
    var model: LLMModel

    init(modalities: ModelModality) {
        model = LLMModel(
            id: "synthetic-readiness", displayName: "Synthetic readiness",
            provider: "Synthetic", modalityOverride: modalities
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
        AsyncThrowingStream { $0.finish() }
    }
}

private struct M02ReadinessVideoSource: MediaVideoFrameSource {
    func durationSeconds() async throws -> Double { 6 }

    func pngFrame(at seconds: Double, maxPixelSize: Int) async throws -> MediaVideoFrameSample {
        MediaVideoFrameSample(
            pngData: try ComposerMediaFixtures589.png(color: CGFloat(seconds) / 6),
            actualSeconds: seconds + 0.125,
            pixelWidth: 8, pixelHeight: 8
        )
    }
}

@Suite("D-MULTIMODAL-04 Composer media readiness")
@MainActor
struct P3AcceptanceM02_ComposerMediaReadinessTests {
    private func makeChat() -> ChatStore {
        let suite = "M02-media-readiness-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        return ChatStore(
            preferencesDefaults: defaults,
            logManager: LogManager(directory: logDirectory)
        )
    }

    @Test("the same attachment changes readiness with the captured model revision")
    func modelSwitchInvalidatesOldImageReadiness() throws {
        let chat = makeChat()
        defer { chat.stopAllStreamingForSafety() }
        let image = ChatAttachment(
            kind: .image, fileName: "synthetic.png", fileType: .image,
            mimeType: "image/png", data: try ComposerMediaFixtures589.png()
        )
        chat.streamingProviderOverride = M02ReadinessProvider(modalities: .vision)
        chat.addComposerDraftAttachment(image)
        chat.draftText = "分析图片"
        let vision = chat.composerMediaReadinessSnapshot
        #expect(vision.attachment(id: image.id)?.readiness == .supported)
        #expect(vision.attachment(id: image.id)?.decision?.isAllowed == true)
        #expect(chat.canSubmitComposerAttachments)

        chat.streamingProviderOverride = M02ReadinessProvider(modalities: .textOnly)
        let textOnly = chat.composerMediaReadinessSnapshot
        #expect(!chat.isCurrentComposerMediaReadiness(vision))
        #expect(vision.selectionRevision != textOnly.selectionRevision)
        #expect(textOnly.attachment(id: image.id)?.readiness == .unsupported)
        #expect(!chat.canSubmitComposerAttachments)
        #expect(chat.composerAttachmentBlockReason == textOnly.blockedReason)
        chat.submitComposer()
        #expect(chat.pendingAttachments.map(\.id) == [image.id])
        #expect(chat.draftText == "分析图片")
        #expect(!chat.messages.contains(where: { $0.role == .user }))
    }

    @Test("a blocked audio payload does not block a separate text-only draft")
    func audioCapabilityGateDoesNotBecomeGlobalTextGate() throws {
        let chat = makeChat()
        defer { chat.stopAllStreamingForSafety() }
        chat.streamingProviderOverride = M02ReadinessProvider(modalities: .textOnly)
        let note = ChatAttachment(
            kind: .text, fileName: "notes.txt", fileType: .text,
            mimeType: "text/plain", data: Data("synthetic note".utf8)
        )
        chat.addComposerDraftAttachment(note)
        #expect(chat.composerMediaReadinessSnapshot.attachment(id: note.id)?.readiness == .referenceOnly)
        #expect(chat.canSubmitComposerAttachments)

        let audio = ChatAttachment(
            kind: .audio, fileName: "voice.wav", fileType: .audio,
            mimeType: "audio/wav", data: Data([0x52, 0x49, 0x46, 0x46])
        )
        chat.addComposerDraftAttachment(audio)
        let blocked = chat.composerMediaReadinessSnapshot
        #expect(blocked.attachment(id: audio.id)?.readiness == .unsupported)
        #expect(blocked.attachment(id: note.id)?.readiness == .referenceOnly)
        #expect(blocked.blockedReason != nil)
        chat.submitComposer()
        #expect(chat.pendingAttachments.map(\.id) == [note.id, audio.id])
        #expect(!chat.messages.contains(where: { $0.role == .user }))

        chat.removePendingAttachment(id: audio.id)
        #expect(chat.canSubmitComposerAttachments)
    }

    @Test("sampled video uses PNG capability while extracted PDF stays a text reference")
    func sampledVideoAndExtractedPDFUseTheirActualInputRepresentation() async throws {
        let chat = makeChat()
        chat.streamingProviderOverride = M02ReadinessProvider(modalities: .vision)
        let video = await ChatStore.resolveVideoAttachment(
            id: UUID(), url: URL(fileURLWithPath: "/synthetic/frames.mp4"),
            name: "frames.mp4", mime: "video/mp4", size: nil,
            source: M02ReadinessVideoSource()
        )
        #expect(video.status == .ready)
        let extractedPDF = ChatAttachment(
            kind: .text, fileName: "pages.pdf", fileType: .unknown,
            mimeType: "application/pdf", data: Data("[原文第 1 页] synthetic".utf8)
        )
        chat.addComposerDraftAttachment(video)
        chat.addComposerDraftAttachment(extractedPDF)
        let vision = chat.composerMediaReadinessSnapshot
        #expect(vision.attachment(id: video.id)?.mimeType == "video/mp4")
        #expect(vision.attachment(id: video.id)?.wireMIMEType == "image/png")
        #expect(vision.attachment(id: video.id)?.readiness == .supported)
        #expect(vision.attachment(id: extractedPDF.id)?.readiness == .referenceOnly)
        #expect(vision.attachment(id: extractedPDF.id)?.wireMIMEType == nil)
        #expect(vision.canSubmitAttachments)

        chat.streamingProviderOverride = M02ReadinessProvider(modalities: .textOnly)
        let textOnly = chat.composerMediaReadinessSnapshot
        #expect(textOnly.attachment(id: video.id)?.readiness == .unsupported)
        #expect(textOnly.attachment(id: extractedPDF.id)?.readiness == .referenceOnly)
        #expect(!textOnly.canSubmitAttachments)
        chat.removePendingAttachment(id: video.id)
        #expect(chat.canSubmitComposerAttachments)
    }
}
