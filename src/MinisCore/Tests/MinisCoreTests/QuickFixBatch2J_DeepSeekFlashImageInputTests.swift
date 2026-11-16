import Foundation
import Testing
@testable import MinisCore

/// Batch2J: deepseek-flash accepts image input per the official vision guide
/// (https://api-docs.deepseek.com/zh-cn/guides/vision/). Mock-only; no network.
@Suite("Batch2J DeepSeek Flash image input (catalog + assembly)")
struct Batch2J_DeepSeekFlashImageInputTests {

    @Test("the generic DeepSeek catalog stays text-only")
    func genericCatalogStaysTextOnly() {
        #expect(!LLMModel.deepSeekFlash.capabilities.supportedModalities.contains(.imageInput))
        #expect(!MediaCapabilityGate.decide(
            mimeType: "image/png", capabilities: LLMModel.deepSeekFlash.capabilities).isAllowed)
        #expect(!LLMModel.deepSeekChat.capabilities.supportedModalities.contains(.imageInput))
        #expect(!LLMModel.deepSeekReasoner.capabilities.supportedModalities.contains(.imageInput))
    }

    @Test("a vision-qualified DeepSeek Flash model assembles a PNG as image_url")
    func flashUserMessageCarriesImageURLBlock() throws {
        let provider = DeepSeekProvider(apiKey: "fixture-key", model: LLMModel.deepSeekFlash.withModalityOverride(.vision),
                                        customBaseURL: DeepSeekProviderContract.baseURL)
        let png = try MediaPayloadFixtures589.png()
        let message = LLMMessage(role: .user, content: "describe",
            images: [LLMMessage.ImageAttachment(mimeType: "image/png", data: png)])
        // Same call and same capability source as OpenAICompatibleProvider's request assembly.
        let dict = OpenAICompatibleProvider.openAIMessageDict(
            message, mediaCapabilities: provider.model.capabilities)
        let parts = try #require(dict["content"] as? [[String: Any]])
        let imageURLs = parts.compactMap { ($0["image_url"] as? [String: Any])?["url"] as? String }
        #expect(imageURLs == ["data:image/png;base64,\(png.base64EncodedString())"])
        #expect(!parts.contains { ($0["text"] as? String)?.contains("[media-gate]") == true })
    }
}
