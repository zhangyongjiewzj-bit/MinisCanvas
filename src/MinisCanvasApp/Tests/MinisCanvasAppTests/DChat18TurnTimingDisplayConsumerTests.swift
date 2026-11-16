import Foundation
import Testing

// MARK: - D-CHAT-18 展示层消费者绑定
//
// 时长数据的展示消费者在 `ChatSidebarView`：
// · 生产转录链（单 NSTextView 承载全部消息）页脚 `ChatTranscriptTurnTimingStrip`
//   —— 最近一个有计时回合的「回合时长 + 阶段耗时 + Provider/模型标识」+ 会话累计总耗时；
// · 气泡元数据行 `ChatMessageMetadataView` —— 每条消息自己的回合时长行。
// 本文件按仓库既有转录契约风格固定「消费者确实接线」，并锁死
// `ChatMessageMetadata.elapsedText`（「已过 N 秒」相对标签）不被误当成 D-CHAT-18 闭环。
@Suite("D-CHAT-18 回合时长展示消费者")
struct DChat18TurnTimingDisplayConsumerTests {
    private func source(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @Test("生产转录链渲染回合时长页脚并绑定会话累计总耗时")
    func transcriptRendersTurnTimingFooter() throws {
        let sidebar = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift"
        )
        for contract in [
            "private struct ChatTranscriptTurnTimingStrip: View",
            "ChatTranscriptTurnTimingStrip(messages: messages)",
            "message.modelTimingDisplayText",
            "ChatStore.conversationTotalDurationText(in: messages)",
            "\"chat.transcript.turnTiming\"",
            "\"回合时长与模型标识\"",
            "\"chat.message.turnTiming.\\(message.id.uuidString)\"",
            // 未闭合回合的实时「已处理时长 + 阶段」由周期时钟驱动（同
            // TaskCenterObservationView 的 TimelineView 先例）。
            "TimelineView(.periodic(from: .now, by: 1))",
        ] {
            #expect(sidebar.contains(contract), "Missing turn-timing consumer: \(contract)")
        }
        let store = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/ChatStore.swift")
        #expect(store.contains("\"已处理 \\(Self.durationText(milliseconds: processed))\""))
        #expect(store.contains("segments.append(\"阶段 \\(firstTokenAt == nil ? \"准备\" : \"生成\")\")"))

        // 页脚必须挂在 ChatTranscriptView（主聊天 + 画布伴随对话共用的生产转录链）内，
        // 而不是只挂在未接线的 ChatBubble 上。
        let transcriptBody = try #require(
            sidebar.range(of: "struct ChatTranscriptView: View").map {
                String(sidebar[$0.lowerBound...])
            }
        )
        #expect(transcriptBody.contains("ChatTranscriptTurnTimingStrip(messages: messages)"))
    }

    @Test("相对时间标签语义保持独立，不冒充回合时长")
    func relativeElapsedLabelKeepsItsOwnSemantics() throws {
        let sidebar = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift"
        )
        // D-CHAT-18 之前就存在的相对标签契约（本轮不得改写）。
        for contract in [
            "static func elapsedText(since timestamp: Date",
            ".accessibilityValue(elapsedText)",
            ".accessibilityIdentifier(\"chat.message.metadata.\\(message.id.uuidString)\")",
        ] {
            #expect(sidebar.contains(contract), "Lost relative-elapsed contract: \(contract)")
        }
        // 回合时长是 ChatStore 侧的独立文案，不复用「已过 N 秒」相对标签。
        let store = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/ChatStore.swift")
        #expect(!store.contains("\"已过"))
        #expect(store.contains("回合 \\(Self.durationText(milliseconds: duration))"))
    }

    @Test("时长/标识元数据只属于展示层，不进入 Provider 组包通道")
    func timingMetadataStaysOutOfProviderPayload() throws {
        let store = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/ChatStore.swift")
        // 附件 → LLM 载荷的通道仍存在且未被本轮改写。
        #expect(store.contains("var llmImages: [LLMMessage.ImageAttachment] {"))
        #expect(store.contains("var llmAudios: [LLMMessage.AudioAttachment] {"))
        // 任何构造 LLM 载荷/持久化消息的行都不不得引用回合时长或回合标识字段。
        let payloadLines = store.split(separator: "\n").filter {
            $0.contains("LLMMessage(") || $0.contains("asPersistedMessage")
        }
        #expect(!payloadLines.isEmpty, "Expected provider payload construction sites to exist")
        for line in payloadLines {
            #expect(
                !line.contains("turnTiming") && !line.contains("turnModelID")
                    && !line.contains("turnProviderName"),
                "D-CHAT-18 metadata leaked into the provider payload line: \(line)"
            )
        }
        // 转录脱敏的真实复制行为由 TranscriptPrivacyFailClosed1945Tests
        // 覆盖；此处只检查 D-CHAT-18 元数据的 Provider 组包边界。
    }
}
