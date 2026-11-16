import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

/// Batch2J: the user's real DeepSeek paths (custom settings record and built-in
/// ProviderType.deepSeek) must admit images for deepseek-flash. Not the
/// disposable-journey channel (isolatedDeepSeekJourneyConfigured stays false).
@Suite("Batch2J DeepSeek Flash image attachment readiness")
@MainActor
struct Batch2J_DeepSeekFlashImageInputTests {
    private func makeChat() -> ChatStore {
        let suite = "Batch2J-\(UUID().uuidString)"
        return ChatStore(
            preferencesDefaults: UserDefaults(suiteName: suite)!,
            logManager: LogManager(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent(suite, isDirectory: true)))
    }

    private func record(named name: String, baseURL: String = DeepSeekProviderContract.baseURL) -> EnvVarEntry {
        EnvVarEntry(name: name, value: "synthetic-fixture", isSecret: true,
            baseURL: baseURL,
            modelNames: ["deepseek-flash", "deepseek-chat"], protocolType: .openaiCompatible)
    }

    private func pngAttachment() throws -> ChatAttachment {
        ChatAttachment(kind: .image, fileName: "synthetic.png", fileType: .image,
            mimeType: "image/png", data: try ComposerMediaFixtures589.png())
    }

    @Test("custom DeepSeek records resolve deepseek-flash with image input, chat stays text-only",
          arguments: ["DEEPSEEK_API_KEY", "deepseek"])
    func customRecordModelDeclaresImageInput(name: String) throws {
        let rec = record(named: name)
        let flash = ChatStore.customProviderModel(record: rec, modelID: "deepseek-flash")
        #expect(flash.capabilities.supportedModalities.contains(.imageInput))
        #expect(MediaCapabilityGate.decide(mimeType: "image/png", capabilities: flash.capabilities).isAllowed)
        let chatModel = ChatStore.customProviderModel(record: rec, modelID: "deepseek-chat")
        #expect(!chatModel.capabilities.supportedModalities.contains(.imageInput))
        let alternatePort = record(named: name, baseURL: "https://api.deepseek.com:8443")
        let alternateModel = ChatStore.customProviderModel(record: alternatePort, modelID: "deepseek-flash")
        #expect(!alternateModel.capabilities.supportedModalities.contains(.imageInput))
    }

    @Test("selecting deepseek-flash on a custom DeepSeek record makes a PNG attachment sendable")
    func customRecordComposerAcceptsImage() throws {
        let chat = makeChat()
        defer { chat.stopAllStreamingForSafety() }
        let rec = record(named: "DEEPSEEK_API_KEY")
        chat.setCustomProvider(rec)
        chat.selectedModelID = "deepseek-flash"
        let image = try pngAttachment()
        chat.addComposerDraftAttachment(image)
        let snapshot = chat.composerMediaReadinessSnapshot
        #expect(snapshot.attachment(id: image.id)?.readiness == .supported)
        #expect(chat.canSubmitComposerAttachments)
        #expect(chat.composerAttachmentBlockReason == nil)
        // The runtime provider is built from the same model (ChatStore frozenCustomProviderConstruction).
        let provider = try chat.frozenCustomProviderConstruction(record: rec, modelID: "deepseek-flash").makeProvider()
        #expect(provider.model.capabilities.supportedModalities.contains(.imageInput))
    }

    @Test("built-in DeepSeek provider with deepseek-flash makes a PNG attachment sendable")
    func builtinComposerAcceptsImage() throws {
        let chat = makeChat()
        defer { chat.stopAllStreamingForSafety() }
        chat.selectedProviderType = .deepSeek
        chat.selectedModelID = "deepseek-flash"
        let image = try pngAttachment()
        chat.addComposerDraftAttachment(image)
        #expect(chat.composerMediaReadinessSnapshot.attachment(id: image.id)?.readiness == .supported)
        #expect(chat.canSubmitComposerAttachments)
        let displayed = try #require(chat.modelOptions.first { $0.id == "deepseek-flash" })
        let selected = try #require(try chat.frozenSelectedProviderConstruction())
        let runtimeModel = try #require(selected.construction.model)
        #expect(runtimeModel == displayed)
        #expect(MediaCapabilityGate.decide(mimeType: "image/png", capabilities: runtimeModel.capabilities).isAllowed)
        #expect(chat.modelOptions.filter { $0.id != "deepseek-flash" }.allSatisfy {
            !$0.capabilities.supportedModalities.contains(.imageInput)
        })
    }
}
