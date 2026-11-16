import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// MARK: - W5-080 D-CHAT-18 回合归属接线（chat-turn-timing-wiring 缺口收口）
//
// 需求：`issues/三期初期合拢-App逐项功能验收清单-20260826.md:175`（CHAT-18，
// 经 `docs/plans/三期毕业选择性优化接入说明-20260921.md:16` 映射 D-CHAT-18 →
// `docs/plans/三期合拢后-全量优化开发Canonical需求总表-20260827.md:367` P3-OBS-01）。
// 焦点队列行 chat-turn-timing-wiring-040 钉住的契约是：用户实际看到的转录行里，
// 「只有模型回合计时」（DChat18TurnTimingTests.swift:380 用例标题原文）。
// 本文件固定其缺失的一半：App 自建的助手行（init 欢迎语、会话读取澄清、
// 本地命令输出）不是模型回合——它们携带真实的 `.appMessage` 回合归属记录
// （随行落定的墙钟端点），但绝不产出时长/阶段/Provider 标识，任何回合写入
// 对其 fail-closed；用户消息保持 `turnTiming == nil`；历史恢复缺计时仍为 nil，
// 与「非模型行」在消费端可区分。不修改、不弱化 DChat18 既有断言。

@Suite("W5-080 App 自建助手行的回合归属")
@MainActor
struct W5ChatTurnTimingWiring080Tests {

    // MARK: 1. 生产者：转录行归属

    @Test("init 欢迎语固化 .appMessage 归属：可见、有真实落定时刻、无时长文案")
    func welcomeSeedCarriesAppMessageOwnershipAndNoDuration() throws {
        let chat = ChatStore()
        let welcome = try #require(chat.messages.first)
        #expect(welcome.role == .assistant)
        let timing = try #require(welcome.turnTiming)
        #expect(timing.owner == .appMessage)
        // 真实端点：该行落定的墙钟（本地文本行没有生成过程，两端点相同是事实；
        // 「不伪造时长」由 owner 投影保证，不是把 nil 冒充成 0）。
        #expect(timing.startedAt == welcome.timestamp)
        #expect(timing.finishedAt == timing.startedAt)
        #expect(timing.phaseTimings.isEmpty)
        #expect(timing.toolCallCount == 0)
        // 时长/阶段/文案投影恒 nil —— 任何 now 下都既无「进行中」也无「已结束」。
        #expect(timing.durationMilliseconds == nil)
        #expect(timing.totalDurationMilliseconds == nil)
        #expect(timing.firstTokenMilliseconds == nil)
        #expect(
            timing.turnDisplayText(providerName: "P", modelID: "m", now: .distantFuture) == nil
        )
        #expect(welcome.turnTimingDisplayText == nil)
        // 闭合态使转录页脚的 TimelineView 选择器不会把欢迎语当进行中回合空转。
        #expect(timing.finishedAt != nil)
    }

    @Test("appendAssistant 两型与澄清行都带归属；appendUser 从不携带")
    func appAuthoredAssistantLinesAreStampedAndUserLinesStayUntimed() throws {
        let chat = ChatStore()
        chat.appendUser("问一句")
        chat.appendAssistant("✅ 已连接：节点A → 节点B")
        let sessionID = try #require(chat.activeSessionID)
        #expect(chat.appendAssistant("跨会话命令输出", toSession: sessionID))

        let userLines = chat.messages.filter { $0.role == .user }
        #expect(userLines.count == 1)
        #expect(userLines.allSatisfy { $0.turnTiming == nil })

        let appLines = chat.messages.filter { $0.role == .assistant }
        #expect(appLines.count == 3)  // 欢迎语 + 两个命令输出
        for line in appLines {
            #expect(line.turnTiming?.owner == .appMessage)
            #expect(line.turnTiming?.durationMilliseconds == nil)
            #expect(line.turnTimingDisplayText == nil)
        }
        // 没有模型回合时，会话累计保持 nil（归属记录不得掺进 0 假象）。
        #expect(ChatStore.conversationTotalDurationMilliseconds(in: chat.messages) == nil)
        #expect(ChatStore.conversationTotalDurationText(in: chat.messages) == nil)
    }

    // MARK: 2. 写入器 fail-closed（只收紧不放宽）

    @Test("阶段/首字/工具/闭合/Provider 快照对 .appMessage 行一律 false 且不改状态")
    func turnWritersRejectAppMessageOwnership() throws {
        let chat = ChatStore()
        let sessionID = try #require(chat.activeSessionID)
        let welcome = try #require(chat.messages.first)
        let welcomeID = welcome.id
        let startedBefore = try #require(welcome.turnTiming?.startedAt)

        #expect(
            !chat.recordTurnPhase(
                .turnSetup, sessionID: sessionID, messageID: welcomeID,
                startedAt: startedBefore, endedAt: startedBefore.addingTimeInterval(0.4)
            )
        )
        #expect(
            !chat.markTurnFirstTokenReceived(
                sessionID: sessionID, messageID: welcomeID,
                at: startedBefore.addingTimeInterval(1)
            )
        )
        #expect(!chat.noteTurnToolCallCompleted(sessionID: sessionID, messageID: welcomeID))
        #expect(
            !chat.closeTurnTiming(
                sessionID: sessionID, messageID: welcomeID,
                at: startedBefore.addingTimeInterval(2)
            )
        )
        #expect(
            !chat.snapshotTurnProviderIdentity(
                sessionID: sessionID, messageID: welcomeID,
                providerName: "SomeProvider", modelID: "some-model"
            )
        )

        let untouched = try #require(chat.messages.first { $0.id == welcomeID })
        #expect(untouched.turnTiming?.owner == .appMessage)
        #expect(untouched.turnTiming?.phaseTimings.isEmpty == true)
        #expect(untouched.turnTiming?.finishedAt == startedBefore)
        #expect(untouched.turnProviderName == nil)
        #expect(untouched.turnModelID == nil)

        // 对照：模型回合归属（owner nil = modelTurn）的写入器行为完全不变。
        let modelLine = ChatMessageUI(
            role: .assistant, content: "模型回合", timestamp: startedBefore,
            turnTiming: ChatTurnTimingMetadata(startedAt: startedBefore)
        )
        chat.messages.append(modelLine)
        #expect(
            chat.recordTurnPhase(
                .turnSetup, sessionID: sessionID, messageID: modelLine.id,
                startedAt: startedBefore, endedAt: startedBefore.addingTimeInterval(0.3)
            )
        )
        #expect(
            chat.snapshotTurnProviderIdentity(
                sessionID: sessionID, messageID: modelLine.id,
                providerName: "FirstProvider", modelID: "first-model"
            )
        )
        #expect(
            chat.closeTurnTiming(
                sessionID: sessionID, messageID: modelLine.id,
                at: startedBefore.addingTimeInterval(4)
            )
        )
        let closed = try #require(chat.messages.first { $0.id == modelLine.id })
        #expect(closed.turnTiming?.durationMilliseconds == 4_000)
        #expect(closed.turnProviderName == "FirstProvider")
        // 累计只含真实模型回合，欢迎语/命令行不掺和。
        #expect(
            ChatStore.conversationTotalDurationMilliseconds(in: chat.messages) == 4_000
        )
    }

    // MARK: 3. 展示消费者：转录页脚选择器跳过归属行

    @Test("页脚选择器语义：归属行不算最近模型回合（源契约）")
    func transcriptStripSkipsOwnershipLines() throws {
        let sidebarPath = "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift"
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MinisCanvasAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // MinisCanvasApp
            .deletingLastPathComponent()   // src
            .deletingLastPathComponent()   // repository
        let sidebar = try String(
            contentsOf: repositoryRoot.appendingPathComponent(sidebarPath), encoding: .utf8
        )
        // 选择器只锁定模型回合归属行（ChatStore 侧唯一投影源）。
        #expect(
            sidebar.contains(
                "$0.role == .assistant && $0.turnTiming?.representsModelTurn == true"
            )
        )
        // D-CHAT-18 既有消费者契约不改写。
        for contract in [
            "private struct ChatTranscriptTurnTimingStrip: View",
            "ChatTranscriptTurnTimingStrip(messages: messages)",
            "message.modelTimingDisplayText",
            "ChatStore.conversationTotalDurationText(in: messages)",
        ] {
            #expect(sidebar.contains(contract), "Lost consumer contract: \(contract)")
        }
    }

    // MARK: 4. 持久化消费者：sidecar 写入闸不被归属行占用

    @Test("归属行不产生 sidecar 回合记录；模型终态回合照常投影")
    func sidecarWriteGateIgnoresOwnershipLines() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let modelTiming = ChatTurnTimingMetadata(
            startedAt: base, finishedAt: base.addingTimeInterval(2)
        )
        let user = ChatMessageUI(role: .user, content: "问题", timestamp: base)
        let welcome = ChatMessageUI(
            role: .assistant, content: ChatStore.welcomeText, timestamp: base,
            turnTiming: ChatTurnTimingMetadata.appMessageTurnTiming(at: base)
        )
        let modelTurn = ChatMessageUI(
            role: .assistant, content: "回答", timestamp: base,
            turnTiming: modelTiming,
            turnProviderName: "Provider 甲", turnModelID: "model-a"
        )
        let thread = ChatThread(id: UUID(), messages: [user, welcome, modelTurn])
        let built = ChatAttachmentPersistence.records(for: thread)
        // 只有终态模型回合产生记录（messageIndex == 2）；归属行不掺和。
        #expect(built.messages.count == 1)
        #expect(built.messages[0].messageIndex == 2)
        #expect(built.messages[0].turnTiming?.timing == modelTiming)

        // 全归属行线程 → 零记录（不占 schema-3 槽位）。
        let onlyApp = ChatThread(id: UUID(), messages: [user, welcome])
        #expect(ChatAttachmentPersistence.records(for: onlyApp).messages.isEmpty)

        // 直接喂记录绕过 load 的投影复核同样要求模型归属（防御纵深）。
        let persisted = thread.asPersisted()
        let reopened = ChatAttachmentPersistence.restoreAttachments(
            from: persisted, records: built.messages
        )
        #expect(reopened.messages.count == 3)
        #expect(reopened.messages[0].turnTiming == nil)
        #expect(reopened.messages[2].turnTiming == modelTiming)
        #expect(reopened.messages[2].turnProviderName == "Provider 甲")
    }

    // MARK: 5. Codable 兼容：owner 可选键

    @Test("缺 owner 键的旧计时 JSON 解码为模型回合；appMessage 可往返")
    func ownerKeyIsBackwardAndForwardCompatible() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970

        // 旧数据形态：无 owner 键 → nil → 按模型回合处理，时长照常产出。
        let legacyTimingJSON =
            "{\"startedAt\":1800000000,\"finishedAt\":1800000002.5,"
            + "\"firstTokenAt\":null,\"phaseTimings\":[],\"toolCallCount\":0}"
        let legacy = try decoder.decode(
            ChatTurnTimingMetadata.self, from: Data(legacyTimingJSON.utf8)
        )
        #expect(legacy.owner == nil)
        #expect(legacy.representsModelTurn)
        #expect(legacy.durationMilliseconds == 2_500)

        // 模型回合（owner nil）编码时省略该键 → 与旧版本字节兼容；往返等值。
        let modelTiming = ChatTurnTimingMetadata(
            startedAt: base, finishedAt: base.addingTimeInterval(1)
        )
        let modelRoundTrip = try decoder.decode(
            ChatTurnTimingMetadata.self, from: try encoder.encode(modelTiming)
        )
        #expect(modelRoundTrip == modelTiming)
        #expect(modelRoundTrip.owner == nil)
        #expect(modelRoundTrip.durationMilliseconds == 1_000)

        // 归属行编码含 appMessage 且等值往返。
        let stamped = ChatTurnTimingMetadata.appMessageTurnTiming(at: base)
        let decoded = try decoder.decode(
            ChatTurnTimingMetadata.self, from: try encoder.encode(stamped)
        )
        #expect(decoded == stamped)
        #expect(decoded.owner == .appMessage)
        #expect(decoded.durationMilliseconds == nil)

        // 未来未知归属值：与 ChatRole 的既有立场一致，解码失败而不是悄悄当作
        // 模型回合（fail-closed，不伪造归属）。
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(
                ChatTurnTimingMetadata.self,
                from: Data(
                    """
                    {"startedAt":1800000000,"finishedAt":null,"firstTokenAt":null,\
                    "phaseTimings":[],"toolCallCount":0,"owner":"quantumTurn"}
                    """.utf8
                )
            )
        }
    }
}
