import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - D-CHAT-18 回合时长 / 阶段耗时 / 总耗时 + Provider·模型标识
//
// 需求：`docs/plans/三期合拢后-全量优化开发Canonical需求总表-20260827.md:367`
// `P3-OBS-01`「用量、日志、版本、健康和运行状态真实可见 …… 过程/耗时不完整」，
// 经 `docs/plans/三期毕业选择性优化接入说明-20260921.md:16` 映射为 `D-CHAT-18`。
// 本文件固定 ChatStore 侧回合契约：
// · 回合时长（提交→终止墙钟）、阶段耗时（准备/首字/生成）、会话累计总耗时；
// · 回合创建时快照的 Provider 名 + canonical 模型标识；
// · 未闭合回合绝不产出时长（不伪造），旧持久化 JSON 缺键解码为 nil；
// · `ChatMessageMetadata.elapsedText`「已过 N 秒」相对标签链路语义不变。

@Suite("D-CHAT-18 回合时长元数据模型")
@MainActor
struct DChat18TurnTimingModelTests {

    @Test("未闭合回合实时给已处理时长与阶段，但绝不产出总耗时")
    func openTurnReportsNoDuration() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        var timing = ChatTurnTimingMetadata(startedAt: started)

        #expect(timing.durationMilliseconds == nil)
        #expect(timing.totalDurationMilliseconds == nil)
        #expect(
            timing.turnDisplayText(
                providerName: "TestProvider", modelID: "test-model",
                now: started.addingTimeInterval(0.3)
            )
                == "回合进行中 · 已处理 300 毫秒 · 阶段 准备 · 服务商 自定义 · 模型 test-model"
        )

        timing.firstTokenAt = started.addingTimeInterval(0.8)
        timing.phase(.firstToken, from: started, to: started.addingTimeInterval(0.8))
        #expect(
            timing.turnDisplayText(providerName: nil, modelID: nil, now: started.addingTimeInterval(1.5))
                == "回合进行中 · 已处理 1.5 秒 · 阶段 生成 · 首字 800 毫秒"
        )

        timing.finishedAt = started.addingTimeInterval(3.0)
        timing.phase(
            .generation, from: started.addingTimeInterval(0.8), to: started.addingTimeInterval(3.0)
        )
        #expect(timing.durationMilliseconds == 3_000)
        #expect(timing.firstTokenMilliseconds == 800)
        #expect(timing.phaseMilliseconds(.generation) == 2_200)
        // 完结后数值稳定：不再随 now 变化。
        #expect(
            timing.turnDisplayText(providerName: nil, modelID: nil, now: started.addingTimeInterval(9_000))
                == "回合 3.0 秒 · 首字 800 毫秒 · 生成 2.2 秒"
        )
    }

    @Test("同名阶段只保留最早一次；重复闭合由 ChatStore 侧保证（见接线用例）")
    func phaseRecordingIsIdempotent() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        var timing = ChatTurnTimingMetadata(startedAt: started)
        timing.recordPhase(.firstToken, milliseconds: 400)
        timing.recordPhase(.firstToken, milliseconds: 9_999)
        #expect(timing.phaseMilliseconds(.firstToken) == 400)
        #expect(timing.phaseTimings.count == 1)
        #expect(timing.phaseTimings.first?.phase == .firstToken)

        timing.finishedAt = started.addingTimeInterval(1)
        #expect(timing.durationMilliseconds == 1_000)
    }

    @Test("时钟回拨不产出负/零假时长，只如实标注不可用")
    func clockSkewYieldsNoFabricatedDuration() {
        let late = Date(timeIntervalSince1970: 2_000_000_000)
        let early = late.addingTimeInterval(-5)
        var timing = ChatTurnTimingMetadata(startedAt: late, finishedAt: early)
        #expect(timing.durationMilliseconds == nil)
        #expect(
            timing.turnDisplayText(providerName: nil, modelID: nil)
                == "回合已结束（时长不可用）"
        )
        timing.phase(.generation, from: late, to: early)
        #expect(timing.phaseMilliseconds(.generation) == nil)
        #expect(ChatTurnTimingMetadata.durationText(milliseconds: -7_000) == "0 毫秒")
    }

    @Test("时长文案按毫秒/秒/分/时分档")
    func durationTextBuckets() {
        #expect(ChatTurnTimingMetadata.durationText(milliseconds: 0) == "0 毫秒")
        #expect(ChatTurnTimingMetadata.durationText(milliseconds: 999) == "999 毫秒")
        #expect(ChatTurnTimingMetadata.durationText(milliseconds: 1_000) == "1.0 秒")
        #expect(ChatTurnTimingMetadata.durationText(milliseconds: 1_500) == "1.5 秒")
        #expect(ChatTurnTimingMetadata.durationText(milliseconds: 45_500) == "45.5 秒")
        #expect(ChatTurnTimingMetadata.durationText(milliseconds: 60_000) == "1 分钟")
        #expect(ChatTurnTimingMetadata.durationText(milliseconds: 90_000) == "1 分 30 秒")
        #expect(ChatTurnTimingMetadata.durationText(milliseconds: 3_720_000) == "1 小时 2 分")
    }

    @Test("Provider/模型标识缺失时省略该段而不是写未知")
    func missingIdentityIsOmitted() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let timing = ChatTurnTimingMetadata(
            startedAt: started, finishedAt: started.addingTimeInterval(1.2)
        )
        #expect(timing.turnDisplayText(providerName: "", modelID: nil) == "回合 1.2 秒")
        #expect(
            timing.turnDisplayText(providerName: nil, modelID: "only-model")
                == "回合 1.2 秒 · 模型 only-model"
        )
        #expect(
            timing.turnDisplayText(providerName: "Only", modelID: "")
                == "回合 1.2 秒 · 服务商 自定义"
        )
    }

    @Test("会话累计只加已闭合回合，跳过无计时与进行中回合")
    func conversationTotalSumsClosedTurnsOnly() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let closed = ChatMessageUI(
            role: .assistant, content: "a",
            turnTiming: ChatTurnTimingMetadata(
                startedAt: base, finishedAt: base.addingTimeInterval(1)
            )
        )
        let closedLong = ChatMessageUI(
            role: .assistant, content: "b",
            turnTiming: ChatTurnTimingMetadata(
                startedAt: base, finishedAt: base.addingTimeInterval(2.5)
            )
        )
        let open = ChatMessageUI(
            role: .assistant, content: "c", isStreaming: true,
            turnTiming: ChatTurnTimingMetadata(startedAt: base)
        )
        let legacy = ChatMessageUI(role: .assistant, content: "d")
        let user = ChatMessageUI(role: .user, content: "e")

        #expect(
            ChatStore.conversationTotalDurationMilliseconds(
                in: [closed, closedLong, open, legacy, user]
            ) == 3_500
        )
        #expect(
            ChatStore.conversationTotalDurationText(in: [closed, closedLong]) == "会话累计 3.5 秒"
        )
        #expect(ChatStore.conversationTotalDurationText(in: [open, legacy, user]) == nil)
    }

    @Test("旧 JSON 无时长键解码为 nil；有时长的消息可往返")
    func codableBackwardAndRoundTrip() throws {
        let legacyJSON = """
        {"id":"3F2A6E42-6E3B-4E5F-9C1B-6F1D2A3B4C5D","role":"assistant","content":"旧会话",\
        "isStreaming":false,"timestamp":1800000000,"toolCalls":[]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let legacy = try decoder.decode(ChatMessageUI.self, from: Data(legacyJSON.utf8))
        #expect(legacy.turnTiming == nil)
        #expect(legacy.turnProviderName == nil)
        #expect(legacy.turnModelID == nil)
        #expect(legacy.turnTimingDisplayText == nil)

        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let message = ChatMessageUI(
            role: .assistant, content: "新会话", timestamp: started,
            turnTiming: ChatTurnTimingMetadata(
                startedAt: started,
                finishedAt: started.addingTimeInterval(2),
                firstTokenAt: started.addingTimeInterval(0.5),
                phaseTimings: [
                    ChatTurnPhaseTiming(phase: .turnSetup, milliseconds: 40),
                    ChatTurnPhaseTiming(phase: .firstToken, milliseconds: 500),
                    ChatTurnPhaseTiming(phase: .generation, milliseconds: 1_500),
                ],
                toolCallCount: 2
            ),
            turnProviderName: "TestProvider",
            turnModelID: "test-model"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(ChatMessageUI.self, from: try encoder.encode(message))
        #expect(decoded == message)
        #expect(decoded.turnTiming?.phaseTimings.count == 3)
        #expect(decoded.turnTiming?.toolCallCount == 2)
        #expect(
            decoded.turnTimingDisplayText?
                .contains("服务商 自定义 · 模型 test-model") == true
        )
    }
}

/// 受控 Provider：延迟 `firstTokenDelay` 后逐段吐出增量；`holdsOpen` 时保持流不结束。
private final class DChat18ScriptedProvider: LLMProvider, @unchecked Sendable {
    private let scriptedName: String
    var firstTokenDelay: TimeInterval
    var chunks: [String]
    var holdsOpen: Bool
    var model: LLMModel

    init(
        providerName: String = "DChat18Provider",
        modelID: String = "d-chat-18-model",
        firstTokenDelay: TimeInterval = 0.12,
        chunks: [String] = ["你好", "，世界"],
        holdsOpen: Bool = false
    ) {
        self.scriptedName = providerName
        self.firstTokenDelay = firstTokenDelay
        self.chunks = chunks
        self.holdsOpen = holdsOpen
        self.model = LLMModel(id: modelID, displayName: modelID, provider: providerName)
    }

    var name: String { scriptedName }
    var capabilities: Set<ProviderCapability> { [.streaming] }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: chunks.joined(), stopReason: "end_turn", usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let delay = firstTokenDelay
        let held = holdsOpen
        let pieces = chunks
        return AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(for: .seconds(delay))
                for piece in pieces {
                    if Task.isCancelled { break }
                    continuation.yield(.text(piece))
                }
                if held {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    continuation.finish(throwing: CancellationError())
                    return
                }
                continuation.yield(.finished(stopReason: "end_turn"))
                continuation.finish()
            }
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                task.cancel()
            }
        }
    }
}

@Suite("D-CHAT-18 ChatStore 回合时长接线")
@MainActor
struct DChat18ChatStoreTurnWiringTests {

    private func waitForStreamEnd(_ chat: ChatStore, timeout: TimeInterval = 10) async throws {
        var waited: TimeInterval = 0
        while chat.isStreaming && waited < timeout {
            try await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        #expect(!chat.isStreaming)
    }

    @Test("已完结回合同时具备回合时长、阶段耗时与 Provider/模型标识")
    func completedTurnCarriesTimingAndIdentity() async throws {
        let chat = ChatStore()
        chat.agentEngine = ComposerSnapshotMockChatEngine()
        chat.streamingProviderOverride = DChat18ScriptedProvider()
        chat.draftText = "说一句问候"
        chat.sendDraft()
        try await waitForStreamEnd(chat)

        let assistant = try #require(chat.messages.last)
        #expect(assistant.role == .assistant)
        #expect(!assistant.isStreaming)
        let timing = try #require(assistant.turnTiming)
        #expect(timing.finishedAt != nil)
        #expect((timing.durationMilliseconds ?? 0) >= 100)
        #expect(timing.phaseMilliseconds(.turnSetup) != nil)
        #expect(timing.phaseMilliseconds(.firstToken) != nil)
        #expect((timing.firstTokenMilliseconds ?? 0) >= 100)
        #expect(timing.phaseMilliseconds(.generation) != nil)
        #expect(assistant.turnProviderName == "DChat18Provider")
        #expect(assistant.turnModelID == "d-chat-18-model")
        let text = try #require(assistant.turnTimingDisplayText)
        #expect(text.contains("回合 "))
        #expect(text.contains("准备 "))
        #expect(text.contains("首字 "))
        #expect(text.contains("生成 "))
        #expect(text.contains("服务商 自定义 · 模型 d-chat-18-model"))
        // 会话累计总耗时 = 唯一已完结回合的时长。
        #expect(
            ChatStore.conversationTotalDurationMilliseconds(in: chat.messages)
                == timing.durationMilliseconds
        )
    }

    @Test("生成中的回合只有阶段进度，绝不产出回合时长/会话总耗时")
    func inFlightTurnReportsNoDuration() async throws {
        let chat = ChatStore()
        chat.agentEngine = ComposerSnapshotMockChatEngine()
        chat.streamingProviderOverride = DChat18ScriptedProvider(holdsOpen: true)
        chat.draftText = "长回复然后停止"
        chat.sendDraft()

        // 等内容上屏（说明首字已到达）但流仍未结束。
        var waited: TimeInterval = 0
        while (chat.messages.last?.content.isEmpty ?? true) && waited < 10 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        #expect(chat.isStreaming)
        let inFlight = try #require(chat.messages.last?.turnTiming)
        #expect(inFlight.finishedAt == nil)
        #expect(inFlight.durationMilliseconds == nil)
        #expect(inFlight.totalDurationMilliseconds == nil)
        #expect(inFlight.firstTokenAt != nil)
        #expect(
            inFlight.turnDisplayText(providerName: nil, modelID: nil, now: Date())
                .map { $0.hasPrefix("回合进行中 · 已处理 ") && $0.contains("阶段 生成") } == true
        )
        // 未闭合的回合在展示文案里也不能出现总耗时段。
        #expect(
            inFlight.turnDisplayText(providerName: nil, modelID: nil, now: Date())?
                .contains("回合 1") == false
        )
        #expect(ChatStore.conversationTotalDurationMilliseconds(in: chat.messages) == nil)

        chat.stopStreaming()
        #expect(!chat.isStreaming)
        let interruptedMessage = try #require(chat.messages.last)
        try #require(interruptedMessage.wasInterrupted)
        #expect(interruptedMessage.turnTimingDisplayText?.contains("已中断 · 用量未回报") == true)
        let stopped = try #require(chat.messages.last?.turnTiming)
        #expect(stopped.finishedAt != nil)
        #expect(stopped.durationMilliseconds != nil)
        #expect(stopped.phaseMilliseconds(.generation) != nil)
        #expect(
            ChatStore.conversationTotalDurationMilliseconds(in: chat.messages)
                == stopped.durationMilliseconds
        )
    }

    @Test("每回合固化自己的 Provider/模型标识，后续回合改选不改写旧行")
    func providerIdentityIsFrozenPerTurn() async throws {
        let chat = ChatStore()
        chat.agentEngine = ComposerSnapshotMockChatEngine()
        chat.streamingProviderOverride = DChat18ScriptedProvider(
            providerName: "FirstProvider", modelID: "first-model"
        )
        chat.draftText = "第一轮"
        chat.sendDraft()
        try await waitForStreamEnd(chat)
        let firstTurnMessageID = try #require(chat.messages.last?.id)

        chat.streamingProviderOverride = DChat18ScriptedProvider(
            providerName: "SecondProvider", modelID: "second-model"
        )
        chat.draftText = "第二轮"
        chat.sendDraft()
        try await waitForStreamEnd(chat)

        let all = chat.messages
        let first = try #require(all.first { $0.id == firstTurnMessageID })
        #expect(first.turnProviderName == "FirstProvider")
        #expect(first.turnModelID == "first-model")
        let second = try #require(all.last)
        #expect(second.turnProviderName == "SecondProvider")
        #expect(second.turnModelID == "second-model")
        #expect(second.id != first.id)
        // 两个回合各有自己的时长，会话累计 = 两者之和。
        let firstTiming = try #require(first.turnTiming)
        let secondTiming = try #require(second.turnTiming)
        #expect(
            ChatStore.conversationTotalDurationMilliseconds(in: all)
                == (firstTiming.durationMilliseconds ?? 0) + (secondTiming.durationMilliseconds ?? 0)
        )
    }

    @Test("用户消息不带回合时长（只有模型回合计时）")
    func nonModelMessagesStayUntimed() async throws {
        let chat = ChatStore()
        chat.agentEngine = ComposerSnapshotMockChatEngine()
        chat.streamingProviderOverride = DChat18ScriptedProvider(chunks: ["答"])
        chat.draftText = "问一句"
        chat.sendDraft()
        try await waitForStreamEnd(chat)

        let userMessages = chat.messages.filter { $0.role == .user }
        #expect(!userMessages.isEmpty)
        #expect(userMessages.allSatisfy { $0.turnTiming == nil })
        #expect(
            chat.messages.filter { $0.role == .assistant }.allSatisfy { $0.turnTiming != nil }
        )
    }

    @Test("时长写入按 (sessionID, messageID) 定位；未知/无计时消息返回 false")
    func timingWritesAreScopedToTheirMessage() throws {
        let chat = ChatStore()
        let sessionID = chat.activeSessionID
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let timed = ChatMessageUI(
            role: .assistant, content: "有计时", timestamp: started,
            turnTiming: ChatTurnTimingMetadata(startedAt: started)
        )
        let legacy = ChatMessageUI(role: .assistant, content: "无计时")
        chat.messages.append(timed)
        chat.messages.append(legacy)

        #expect(
            chat.recordTurnPhase(
                .turnSetup, sessionID: sessionID, messageID: timed.id,
                startedAt: started, endedAt: started.addingTimeInterval(0.3)
            )
        )
        #expect(
            !chat.recordTurnPhase(
                .turnSetup, sessionID: sessionID, messageID: legacy.id,
                startedAt: started, endedAt: started.addingTimeInterval(0.3)
            )
        )
        #expect(!chat.closeTurnTiming(sessionID: sessionID, messageID: UUID()))
        #expect(
            !chat.snapshotTurnProviderIdentity(
                sessionID: nil, messageID: timed.id, providerName: "P", modelID: "m"
            )
        )

        // 同名阶段与重复闭合都幂等。
        #expect(
            chat.recordTurnPhase(
                .turnSetup, sessionID: sessionID, messageID: timed.id,
                startedAt: started, endedAt: started.addingTimeInterval(9)
            )
        )
        #expect(
            chat.markTurnFirstTokenReceived(
                sessionID: sessionID, messageID: timed.id, at: started.addingTimeInterval(1)
            )
        )
        #expect(
            chat.markTurnFirstTokenReceived(
                sessionID: sessionID, messageID: timed.id, at: started.addingTimeInterval(50)
            )
        )
        #expect(chat.noteTurnToolCallCompleted(sessionID: sessionID, messageID: timed.id))
        #expect(chat.closeTurnTiming(sessionID: sessionID, messageID: timed.id,
                                     at: started.addingTimeInterval(4)))
        #expect(chat.closeTurnTiming(sessionID: sessionID, messageID: timed.id,
                                     at: started.addingTimeInterval(900)))

        let stored = try #require(chat.messages.first { $0.id == timed.id }?.turnTiming)
        #expect(stored.phaseMilliseconds(.turnSetup) == 300)
        #expect(stored.phaseMilliseconds(.firstToken) == 1_000)
        #expect(stored.phaseMilliseconds(.generation) == 3_000)
        #expect(stored.durationMilliseconds == 4_000)
        #expect(stored.toolCallCount == 1)
        #expect(
            stored.turnDisplayText(providerName: nil, modelID: nil)
                == "回合 4.0 秒 · 准备 300 毫秒 · 首字 1.0 秒 · 生成 3.0 秒 · 工具 1 次"
        )
        // 无计时消息（历史恢复）永远不会被写成有时长。
        #expect(chat.messages.first { $0.id == legacy.id }?.turnTiming == nil)
    }

    @Test("安全锁终止路径闭合回合时长")
    func safetyStopClosesTurnTiming() async throws {
        let chat = ChatStore()
        chat.agentEngine = ComposerSnapshotMockChatEngine()
        chat.streamingProviderOverride = DChat18ScriptedProvider(holdsOpen: true)
        chat.draftText = "被安全锁终止的回合"
        chat.sendDraft()

        var waited: TimeInterval = 0
        while !chat.isStreaming && waited < 10 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        #expect(chat.isStreaming)
        chat.stopAllStreamingForSafety()
        #expect(!chat.isStreaming)

        let stopped = try #require(chat.messages.last?.turnTiming)
        #expect(stopped.finishedAt != nil)
        #expect(stopped.durationMilliseconds != nil)
        #expect(
            stopped.turnDisplayText(providerName: nil, modelID: nil)?.hasPrefix("回合 ") == true
        )
    }
}
