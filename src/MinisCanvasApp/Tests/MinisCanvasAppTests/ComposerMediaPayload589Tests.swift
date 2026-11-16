import CoreGraphics
import Foundation
import ImageIO
import MinisCore
import Testing
@testable import MinisCanvasApp

enum ComposerMediaFixtures589 {
    static func png(color: CGFloat = 0.5) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 8, height: 8,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: color, green: 0.2, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static let wav: Data = {
        var bytes = Array("RIFF".utf8)
        func u16(_ v: UInt16) { bytes += [UInt8(v & 255), UInt8(v >> 8)] }
        func u32(_ v: UInt32) { bytes += [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8(v >> 24)] }
        u32(52); bytes += Array("WAVEfmt ".utf8); u32(16)
        u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
        bytes += Array("data".utf8); u32(16); bytes += [UInt8](repeating: 0, count: 16)
        return Data(bytes)
    }()
}

@Suite("Media589 Composer actual payload admission")
@MainActor
struct ComposerMediaPayload589Tests {
    private func chat() -> ChatStore {
        let id = "media589-\(UUID().uuidString)"
        return ChatStore(preferencesDefaults: UserDefaults(suiteName: id)!,
            logManager: LogManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(id)))
    }

    private func provider(anthropic: Bool = false) -> any LLMProvider {
        let model = LLMModel(id: "owned-media589", displayName: "Owned fixture", provider: "Synthetic", modalityOverride: .fullMultimodalInput)
        let placeholder = "[configured locally]"
        if anthropic { return AnthropicProvider(apiKey: placeholder, model: model) }
        return OpenAICompatibleProvider(apiKey: placeholder, model: model)
    }

    @Test func actualMIMEMismatchBlocksOrdinarySubmitWithoutLosingDraft() throws {
        let chat = chat()
        defer { chat.stopAllStreamingForSafety() }
        chat.streamingProviderOverride = provider()
        let item = ChatAttachment(kind: .image, fileName: "looks.jpeg", fileType: .image,
            mimeType: "image/jpeg", data: try ComposerMediaFixtures589.png())
        chat.addComposerDraftAttachment(item); chat.draftText = "owned draft"
        let snapshot = chat.composerMediaReadinessSnapshot
        #expect(snapshot.attachment(id: item.id)?.readiness == .unsupported)
        #expect(snapshot.blockedReason?.contains("实际字节") == true)
        #expect(!chat.canSubmitComposerAttachments)
        chat.submitComposer()
        #expect(chat.pendingAttachments.map(\.id) == [item.id])
        #expect(chat.draftText == "owned draft")
        #expect(!chat.messages.contains { $0.role == .user })
        chat.removePendingAttachment(id: item.id)
        #expect(chat.canSubmitComposerAttachments)
    }

    @Test("configured LUNA vision model admits a real PNG at the Composer boundary")
    func lunaVisionModelAdmitsPNG() throws {
        let chat = chat()
        defer { chat.stopAllStreamingForSafety() }
        let luna = EnvVarEntry(
            name: "LUNA", value: "sk-owned-luna", isSecret: true,
            baseURL: "https://luna.example.test/v1",
            modelNames: ["gpt-5.6-luna"], protocolType: .openaiCompatible
        )
        chat.providerRecordsSource = { [luna] }
        chat.setCustomProvider(luna)
        #expect(chat.applyPickedModel(modelID: "gpt-5.6-luna"))
        let item = ChatAttachment(
            kind: .image, fileName: "owned.png", fileType: .image,
            mimeType: "image/png", data: try ComposerMediaFixtures589.png()
        )
        chat.addComposerDraftAttachment(item)

        let snapshot = chat.composerMediaReadinessSnapshot
        #expect(snapshot.attachment(id: item.id)?.readiness == .supported)
        #expect(snapshot.attachment(id: item.id)?.decision?.isAllowed == true)
        #expect(chat.canSubmitComposerAttachments)
    }

    @Test func truncatedImageAndRawHEICDoNotAcquireSupportedReadiness() throws {
        let chat = chat()
        defer { chat.stopAllStreamingForSafety() }
        chat.streamingProviderOverride = provider()
        for (mime, bytes) in [("image/png", Data(try ComposerMediaFixtures589.png().prefix(8))),
                              ("image/heic", Data("owned unsupported source".utf8))] {
            let item = ChatAttachment(kind: .image, fileName: "owned", fileType: .image, mimeType: mime, data: bytes)
            chat.addComposerDraftAttachment(item)
            #expect(chat.composerMediaReadinessSnapshot.attachment(id: item.id)?.readiness == .unsupported)
            #expect(!chat.canSubmitComposerAttachments)
            chat.removePendingAttachment(id: item.id)
        }
        #expect(chat.canSubmitComposerAttachments)
    }

    @Test func audioFormatUsesContainerAndWireSwitchRecomputesReadiness() throws {
        let chat = chat()
        defer { chat.stopAllStreamingForSafety() }
        let item = ChatAttachment(kind: .audio, fileName: "misleading.mp3", fileType: .audio,
            mimeType: "audio/wav", data: ComposerMediaFixtures589.wav)
        #expect(item.audioAttachment?.format == "wav")
        #expect(item.audioAttachment?.base64Data == ComposerMediaFixtures589.wav.base64EncodedString())
        chat.streamingProviderOverride = provider()
        chat.addComposerDraftAttachment(item)
        let compatible = chat.composerMediaReadinessSnapshot
        #expect(compatible.wireProtocol == .openaiCompatible)
        #expect(compatible.attachment(id: item.id)?.readiness == .supported)
        chat.streamingProviderOverride = provider(anthropic: true)
        let anthropic = chat.composerMediaReadinessSnapshot
        #expect(anthropic.wireProtocol == .anthropic)
        #expect(anthropic.attachment(id: item.id)?.readiness == .unsupported)
        #expect(!chat.canSubmitComposerAttachments)
        chat.submitComposer()
        #expect(chat.pendingAttachments.map(\.id) == [item.id])
        #expect(!chat.messages.contains { $0.role == .user })
        chat.streamingProviderOverride = provider()
        #expect(chat.composerMediaReadinessSnapshot.attachment(id: item.id)?.readiness == .supported)
    }
}
