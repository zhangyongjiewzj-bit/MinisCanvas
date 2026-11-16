import Foundation
import Testing
@testable import MinisCanvasApp

// D-CHAT-03「生成中状态清晰」（issues/三期初期合拢-App逐项功能验收清单-20260826.md:160）
// 的转录渲染回归：流式 assistant 消息在首个文本块到达前正文为空，转录必须
// 原位显示占位提示；同时占位只能存在于渲染/无障碍层——落盘条目与复制用纯文本
// 不得被污染。

@Suite("D-CHAT-03 流式生成中占位（转录渲染层）")
@MainActor
struct DChat03StreamingPlaceholderTests {

    private func message(
        _ role: ChatRole, content: String, streaming: Bool
    ) -> ChatMessageUI {
        var ui = ChatMessageUI(role: role, content: content)
        ui.isStreaming = streaming
        return ui
    }

    @Test func emptyStreamingAssistantShowsPlaceholderInRenderLayerOnly() async throws {
        await ChatTranscriptStatusIconProjection.preload()
        let messages = [message(.user, content: "问题", streaming: false),
                        message(.assistant, content: "", streaming: true)]

        let rendered = ChatTranscriptFormatter.attributedString(messages).string
        #expect(
            rendered.contains("\u{FFFC}") && rendered.contains("生成中…"),
            "生成中的空正文 assistant 消息必须在转录中可见地提示状态：\(rendered)"
        )
        #expect(
            ChatTranscriptFormatter.accessibilityText(messages)
                .contains("生成中…")
                && !ChatTranscriptFormatter.accessibilityText(messages).contains("\u{FFFC}"),
            "无障碍播报与可见转录同步，不朗读对象替换字符"
        )
        // 纯文本（复制）与持久化条目不携带占位。
        #expect(
            !ChatTranscriptFormatter.plainText(messages)
                .contains(ChatTranscriptFormatter.streamingPlaceholder)
        )
        let persisted = ChatTranscriptFormatter.persistedEntries(messages)
        #expect(
            !persisted.contains { $0.text.contains(ChatTranscriptFormatter.streamingPlaceholder) },
            "落盘条目不得写入渲染占位"
        )
    }

    @Test func settledOrNonStreamingEmptyAssistantGetsNoPlaceholder() throws {
        let settled = [message(.assistant, content: "", streaming: false)]
        let user = [message(.user, content: "", streaming: false)]
        for group in [settled, user] {
            #expect(
                !ChatTranscriptFormatter.attributedString(group).string.contains("生成中…")
                    && !ChatTranscriptFormatter.attributedString(group).string.contains("\u{FFFC}"),
                "只有正在流式的 assistant 消息才显示生成中占位"
            )
        }
    }

    @Test func placeholderDisappearsOnceFirstChunkArrives() throws {
        let messages = [message(.assistant, content: "第一段。", streaming: true)]
        let rendered = ChatTranscriptFormatter.attributedString(messages).string
        #expect(rendered.contains("第一段。"))
        #expect(
            !rendered.contains("生成中…") && !rendered.contains("\u{FFFC}"),
            "已有正文后不得再叠占位，避免转录出现假「生成中」"
        )
    }
}
