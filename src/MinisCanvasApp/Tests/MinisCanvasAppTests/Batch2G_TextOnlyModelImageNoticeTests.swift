import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Batch2G RED 3（M14）：给纯文本模型（deepseek-chat）附图片时，附件栏提示是英文拼接
/// “附件不可发送：the selected model does not declare image input capability.。请更换…”，
/// 且状态行同时显示“就绪”。
/// 英文来源：MinisCore MediaCapabilityGate.swift:131（decide 的 reason）经 ChatStore.swift:2528
/// 原样拼进 reason；“就绪”来自 ComposerAttachmentPresentation.status(for:)（只看 data != nil，
/// ComposerAttachmentPresentation.swift:35/80）并被 GlobalComposerView.swift:1055、ChatSidebarView.swift:3634 展示。
/// 需要新符号：`ComposerAttachmentPresentation.statusLabel(for:in:)`（结合就绪快照的状态行文案）。
@Suite("Batch2G text-only model image notice", .serialized)
@MainActor
struct Batch2G_TextOnlyModelImageNoticeTests {
    private final class TextOnlyProvider: LLMProvider, @unchecked Sendable {
        let name = "DeepSeek"
        var model = LLMModel(id: "deepseek-chat", displayName: "DeepSeek Chat", provider: "DeepSeek",
                             modalityOverride: [.textInput])
        func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                         temperature: Double?) async throws -> LLMResponse {
            LLMResponse(text: "ok", stopReason: "end_turn", usage: nil)
        }
        func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                           temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private func fixture() throws -> (ChatStore, ChatAttachment, ComposerMediaReadinessSnapshot) {
        let id = "batch2g-m14-\(UUID().uuidString)"
        let chat = ChatStore(preferencesDefaults: UserDefaults(suiteName: id)!,
            logManager: LogManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(id)))
        chat.streamingProviderOverride = TextOnlyProvider()
        let item = ChatAttachment(kind: .image, fileName: "photo.png", fileType: .image,
            mimeType: "image/png", data: try ComposerMediaFixtures589.png())
        chat.addComposerDraftAttachment(item)
        return (chat, item, chat.composerMediaReadinessSnapshot)
    }

    @Test("rejection reason is fully Chinese, names the model, and points to a way out")
    func reasonIsChineseNamesModelAndGuides() throws {
        let (chat, item, snapshot) = try fixture()
        defer { chat.stopAllStreamingForSafety() }
        let entry = try #require(snapshot.attachment(id: item.id))
        #expect(entry.readiness == .unsupported)
        let reason = entry.reason
        #expect(reason.contains("DeepSeek Chat"))
        #expect(reason.contains("不支持图片输入"))
        #expect(reason.contains("选择"))   // 选择支持图片的模型 / 去选择模型
        // 去掉模型名后不得残留英文单词（如 selected model / declare / capability）。
        let withoutModel = reason.replacingOccurrences(of: "DeepSeek Chat", with: "")
        #expect(withoutModel.range(of: "[A-Za-z]{3,}", options: .regularExpression) == nil)
        // 不再有“。。”式英文句号拼接。
        #expect(!reason.contains(".。"))
        #expect(snapshot.blockedReason == reason)
    }

    @Test("status line does not say 就绪 for an attachment the model cannot receive")
    func statusLineIsNotReadyWhenUnsupported() throws {
        let (chat, item, snapshot) = try fixture()
        defer { chat.stopAllStreamingForSafety() }
        let label = ComposerAttachmentPresentation.statusLabel(for: item, in: snapshot)
        #expect(label != "就绪")
        #expect(!label.isEmpty)
    }
}
