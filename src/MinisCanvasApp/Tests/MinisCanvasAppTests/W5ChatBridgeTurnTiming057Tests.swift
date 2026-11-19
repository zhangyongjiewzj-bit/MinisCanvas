import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - W5-CHAT-BRIDGE-TIMING-057（D-CHAT-18 residual：回合耗时 sidecar 投影）
//
// 需求缺口：lane 040 的 `ChatMessageUI.turnTiming/turnProviderName/turnModelID`
// 只存在于内存。真实重启路径 ChatStore.swift:4870-4892（load + restoreAttachments
// → MinisCore.ChatSession.asThread → LLMMessage.asChatMessageUI）会丢掉这些
// App 展示元数据。本 lane 在 ChatSessionBridge 的 sidecar 上加最窄投影：
// schema 3 只存「已终态回合」的耗时与回合创建时冻结的 Provider/模型快照。
// 语义红线：投影的是终态累计耗时＋冻结标识值，不是 ChatSidebarView elapsedText
// 的消息级相对时间戳；未完成回合绝不落盘（否则重启后活钟会伪造终值）。

@Suite("W5-057 回合耗时 sidecar 投影")
struct W5ChatBridgeTurnTiming057Tests {

    private func makeTempRoot(_ tag: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("w5-057-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 终态回合元数据：固定墙钟值，避免时钟抖动导致断言 flake。
    private func terminalTiming() -> ChatTurnTimingMetadata {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var timing = ChatTurnTimingMetadata(startedAt: startedAt)
        timing.firstTokenAt = startedAt.addingTimeInterval(1.25)
        timing.finishedAt = startedAt.addingTimeInterval(4.5)
        timing.recordPhase(.firstToken, milliseconds: 1_250)
        timing.recordPhase(.generation, milliseconds: 3_250)
        timing.toolCallCount = 2
        return timing
    }

    private func inFlightTiming() -> ChatTurnTimingMetadata {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var timing = ChatTurnTimingMetadata(startedAt: startedAt)
        timing.firstTokenAt = startedAt.addingTimeInterval(0.8)
        // finishedAt 保持 nil：展示层此时渲染「回合进行中」活钟。
        return timing
    }

    // MARK: 1. 终态回合往返保真

    @Test("终态回合的耗时与冻结 Provider/模型跨 save/load/restore 保真")
    func terminalTurnRoundTripPreservesTimingAndFrozenIdentity() throws {
        let root = try makeTempRoot("terminal-roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }

        let timing = terminalTiming()
        let user = ChatMessageUI(role: .user, content: "原始问题")
        let assistant = ChatMessageUI(
            role: .assistant,
            content: "回答内容",
            turnTiming: timing,
            turnProviderName: "Provider 甲",
            turnModelID: "model-x-2026"
        )
        let thread = ChatThread(id: UUID(), messages: [user, assistant])

        // 写入闸：终态 assistant 回合被投影，且只有它产生记录（persistedIndex=1）。
        let built = ChatAttachmentPersistence.records(for: thread)
        #expect(built.messages.count == 1)
        #expect(built.messages[0].messageIndex == 1)
        #expect(built.messages[0].turnTiming?.timing == timing)
        #expect(built.messages[0].turnTiming?.providerName == "Provider 甲")
        #expect(built.messages[0].turnTiming?.modelID == "model-x-2026")

        try ChatAttachmentPersistence.save(sessions: [thread], to: root)
        let loaded = try ChatAttachmentPersistence.load(from: root)
        let records = try #require(loaded[thread.id.uuidString])
        #expect(records.count == 1)
        #expect(records[0].turnTiming?.timing == timing)
        #expect(records[0].turnTiming?.providerName == "Provider 甲")
        #expect(records[0].turnTiming?.modelID == "model-x-2026")

        // 重启路径：持久化模型 → asThread 丢失内存元数据 → sidecar 投影补回。
        let persisted = thread.asPersisted()
        let bare = persisted.asThread()
        #expect(bare.messages[1].turnTiming == nil)  // 缺口本身：不投影则必 nil

        let reopened = ChatAttachmentPersistence.restoreAttachments(
            from: persisted, records: records
        )
        #expect(reopened.messages.count == 2)
        #expect(reopened.messages[0].turnTiming == nil)   // user 消息从不携带
        #expect(reopened.messages[1].turnTiming == timing)
        #expect(reopened.messages[1].turnProviderName == "Provider 甲")
        #expect(reopened.messages[1].turnModelID == "model-x-2026")
        // 消费端文案一致：终态展示文本由冻结值计算，不依赖当前 Provider/模型选择。
        #expect(reopened.messages[1].turnTimingDisplayText == assistant.turnTimingDisplayText)
    }

    // MARK: 2. 未完成回合不投影（防止重启后活钟伪造终值）

    @Test("未完成回合不投影：写入闸跳过，重启后不出现进行中假象")
    func inFlightTurnIsNeverProjected() throws {
        let root = try makeTempRoot("inflight")
        defer { try? FileManager.default.removeItem(at: root) }

        let attachment = ChatAttachment(
            kind: .text, fileName: "note.txt", fileType: .text, data: Data("n".utf8)
        )
        // 进行中回合 + 附件：附件记录照常存在，但 turn 键必须为空。
        let assistant = ChatMessageUI(
            role: .assistant,
            content: "仍在流式输出的回答",
            attachments: [attachment],
            turnTiming: inFlightTiming(),
            turnProviderName: "Provider 甲",
            turnModelID: "model-x-2026"
        )
        let thread = ChatThread(id: UUID(), messages: [assistant])

        let built = ChatAttachmentPersistence.records(for: thread)
        #expect(built.messages.count == 1)                    // 附件记录仍在
        #expect(built.messages[0].attachments == [attachment])
        #expect(built.messages[0].turnTiming == nil)          // 但回合不投影

        try ChatAttachmentPersistence.save(sessions: [thread], to: root)
        let loaded = try ChatAttachmentPersistence.load(from: root)
        let records = try #require(loaded[thread.id.uuidString])
        #expect(records[0].turnTiming == nil)

        let reopened = ChatAttachmentPersistence.restoreAttachments(
            from: thread.asPersisted(), records: records
        )
        #expect(reopened.messages[0].attachments == [attachment])
        #expect(reopened.messages[0].turnTiming == nil)
        #expect(reopened.messages[0].turnProviderName == nil)
        #expect(reopened.messages[0].turnModelID == nil)
    }

    @Test("restore 兜底闸：绕过 load 直接注入未完成回合记录也不复活活钟")
    func restoreRejectsNonTerminalRecordInjectedDirectly() {
        let assistant = ChatMessageUI(role: .assistant, content: "回答")
        let thread = ChatThread(id: UUID(), messages: [assistant])
        let persisted = thread.asPersisted()

        // 借用同内容终态记录的 messageIndex/contentDigest（指纹围栏应通过），
        // 再把 turn 键换成未终态快照，验证 restore 侧兜底闸。
        let terminalRecord = ChatAttachmentPersistence.records(for: ChatThread(
            id: thread.id,
            messages: [ChatMessageUI(
                role: .assistant,
                content: "回答",
                turnTiming: terminalTiming()
            )]
        )).messages[0]
        var record = terminalRecord
        record.turnTiming = ChatAttachmentPersistence.TurnTimingRecord(
            timing: inFlightTiming(),
            providerName: "Provider 甲",
            modelID: "model-x-2026"
        )
        let reopened = ChatAttachmentPersistence.restoreAttachments(
            from: persisted, records: [record]
        )
        #expect(reopened.messages[0].turnTiming == nil)
        #expect(reopened.messages[0].turnProviderName == nil)
        #expect(reopened.messages[0].turnModelID == nil)
    }

    // MARK: 3. 旧 schema 档案：不炸且不携带 turn 键

    /// schema 1/2 先例：`<2` 剥 trusted intent；本 lane 扩到 `<3` 剥 turn 键。
    @Test("schema 1/2 旧 sidecar 正常读取且 turnTiming 键被剥离")
    func legacySchemaEnvelopesLoadWithoutTurnKeys() throws {
        let root = try makeTempRoot("legacy-schema")
        defer { try? FileManager.default.removeItem(at: root) }

        // 合法旧档（schema 2）：只有附件与 trusted intent，没有 turn 键。
        let schema2 = Data(
            """
            {"schemaVersion":2,"sessions":[{"sessionID":"legacy-2","messages":[\
            {"messageIndex":0,"contentDigest":"ab","attachments":[],\
            "trustedSessionReadIntent":" 读取 "}]}]}
            """.utf8
        )
        try schema2.write(to: ChatAttachmentPersistence.url(in: root))
        var loaded = try ChatAttachmentPersistence.load(from: root)
        var records = try #require(loaded["legacy-2"])
        #expect(records.count == 1)
        #expect(records[0].turnTiming == nil)
        #expect(records[0].trustedSessionReadIntent == nil)

        // 手改旧档伪装携带 turn 键（schema 2）：沿用 fail-closed 先例，剥离。
        let forgedSchema2 = Data(
            """
            {"schemaVersion":2,"sessions":[{"sessionID":"legacy-forged","messages":[\
            {"messageIndex":0,"contentDigest":"ab","attachments":[],\
            "turnTiming":{"timing":{"startedAt":100,"finishedAt":200,"firstTokenAt":null,\
            "phaseTimings":[],"toolCallCount":0},"providerName":"P","modelID":"M"}}]}]}
            """.utf8
        )
        try forgedSchema2.write(to: ChatAttachmentPersistence.url(in: root))
        loaded = try ChatAttachmentPersistence.load(from: root)
        records = try #require(loaded["legacy-forged"])
        #expect(records[0].turnTiming == nil)

        // schema 1：trusted intent 与 turn 键同被剥离。
        let schema1 = Data(
            """
            {"schemaVersion":1,"sessions":[{"sessionID":"legacy-1","messages":[\
            {"messageIndex":0,"contentDigest":"ab","attachments":[],\
            "trustedSessionReadIntent":"意图"}]}]}
            """.utf8
        )
        try schema1.write(to: ChatAttachmentPersistence.url(in: root))
        loaded = try ChatAttachmentPersistence.load(from: root)
        records = try #require(loaded["legacy-1"])
        #expect(records[0].turnTiming == nil)
        #expect(records[0].trustedSessionReadIntent == nil)
    }

    @Test("schema 3 手改档携带未完成回合快照时读取即剥离，不复活进行中假象")
    func schema3NonTerminalRecordIsStrippedOnLoad() throws {
        let root = try makeTempRoot("schema3-nonterminal")
        defer { try? FileManager.default.removeItem(at: root) }

        let forged = Data(
            """
            {"schemaVersion":3,"sessions":[{"sessionID":"forged-live","messages":[\
            {"messageIndex":0,"contentDigest":"ab","attachments":[],\
            "turnTiming":{"timing":{"startedAt":100,"finishedAt":null,"firstTokenAt":150,\
            "phaseTimings":[],"toolCallCount":0},"providerName":"P","modelID":"M"}}]}]}
            """.utf8
        )
        try forged.write(to: ChatAttachmentPersistence.url(in: root))
        let records = try #require(try ChatAttachmentPersistence.load(from: root)["forged-live"])
        #expect(records[0].turnTiming == nil)
    }

    // MARK: 4. 指纹围栏对 turn 键同样生效

    @Test("内容指纹不匹配时 turn 元数据不得错误挂接到改写后的消息")
    func digestFenceAlsoGuardsTurnProjection() throws {
        let root = try makeTempRoot("digest-fence")
        defer { try? FileManager.default.removeItem(at: root) }

        let thread = ChatThread(id: UUID(), messages: [
            ChatMessageUI(
                role: .assistant,
                content: "原回答",
                turnTiming: terminalTiming(),
                turnProviderName: "Provider 甲",
                turnModelID: "model-x-2026"
            )
        ])
        try ChatAttachmentPersistence.save(sessions: [thread], to: root)
        let loaded = try ChatAttachmentPersistence.load(from: root)
        let records = try #require(loaded[thread.id.uuidString])
        #expect(records[0].turnTiming != nil)

        // 转录被编辑（内容变化、索引不变）：digest 围栏必须拒绝挂接。
        var edited = thread.asPersisted()
        edited.messages[0] = LLMMessage(role: .assistant, content: "被改写的回答")
        let reopened = ChatAttachmentPersistence.restoreAttachments(
            from: edited, records: records
        )
        #expect(reopened.messages[0].turnTiming == nil)
        #expect(reopened.messages[0].turnProviderName == nil)
        #expect(reopened.messages[0].turnModelID == nil)
    }

    // MARK: 5. R3-09 每条消息的真实时间

    /// 修后复核：回合中现场转换的消息（工具往来、合并后的中间消息）时间可信，不得标成"未核实"，
    /// 否则跑过工具的回合，"回退会话并恢复文件"会不再自动恢复文件。只有从磁盘读出的消息才标。
    @Test func liveConvertedMessagesKeepTrustedTimesOnlyDiskLoadsAreUnverified() {
        let call = LLMToolCall(id: "c1", name: "file_write", rawArguments: "{}", arguments: [:])
        let live = [LLMMessage(role: .assistant, content: "", toolCalls: [call]),
                    LLMMessage(role: .tool, content: "ok", toolCallID: "c1")].map { $0.asChatMessageUI() }
        #expect(live.allSatisfy { !$0.hasUnverifiedTimestamp })
        let thread = ChatThread(id: UUID(), messages: [ChatMessageUI(role: .user, content: "改文件")])
        #expect(thread.asPersisted().asThread().messages.allSatisfy { $0.hasUnverifiedTimestamp })
    }

    @Test("R3-09：普通消息的真实时间跨 save/reopen 保真；改写过的消息与未核实消息不回填、不写假时间")
    func messageTimestampsSurviveReopen() throws {
        let root = try makeTempRoot("message-times")
        defer { try? FileManager.default.removeItem(at: root) }
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let thread = ChatThread(id: UUID(), messages: [
            ChatMessageUI(role: .user, content: "改一个文件", timestamp: t0),
            ChatMessageUI(role: .assistant, content: "好的", timestamp: t0.addingTimeInterval(5)),
        ])
        // 普通消息没有附件/回合元数据，不产生附件记录，但时间照样落盘。
        #expect(ChatAttachmentPersistence.records(for: thread).messages.isEmpty)
        try ChatAttachmentPersistence.save(session: thread, to: root)
        let id = thread.id.uuidString
        let records = try #require(try ChatAttachmentPersistence.load(forSessionID: id, from: root))
        let times = try ChatAttachmentPersistence.loadMessageTimes(forSessionID: id, from: root)
        #expect(times.count == 2)

        let reopened = ChatAttachmentPersistence.restoreAttachments(
            from: thread.asPersisted(), records: records, messageTimes: times)
        #expect(reopened.messages.map(\.timestamp) == [t0, t0.addingTimeInterval(5)])
        #expect(reopened.messages.allSatisfy { !$0.hasUnverifiedTimestamp })

        // 旧数据没有消息时间：保持“时间未核实”，且再次落盘时不把启动时刻写成真实时间。
        let bare = ChatAttachmentPersistence.restoreAttachments(from: thread.asPersisted(), records: records)
        #expect(bare.messages.allSatisfy { $0.hasUnverifiedTimestamp })
        #expect(ChatAttachmentPersistence.records(for: bare).messageTimes == nil)

        // 内容被改写：摘要对不上，不把旧时间挂到别的消息上。
        var edited = thread.asPersisted()
        edited.messages[1] = LLMMessage(role: .assistant, content: "改写过")
        let fenced = ChatAttachmentPersistence.restoreAttachments(
            from: edited, records: records, messageTimes: times)
        #expect(fenced.messages[0].timestamp == t0 && !fenced.messages[0].hasUnverifiedTimestamp)
        #expect(fenced.messages[1].hasUnverifiedTimestamp)
    }

    @Test("R3-09：旧文件没有 messageTimes 键照常读取；旧档的终态助手回合用回合创建时刻作为可信时间")
    func legacySidecarWithoutTimesAndTurnStartFallback() throws {
        let root = try makeTempRoot("message-times-legacy")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let shard = ChatAttachmentPersistence.sessionSidecarURL(for: id, in: root)
        try Data("""
        {"schemaVersion":5,"sessions":[{"sessionID":"\(id.uuidString)","messages":[]}]}
        """.utf8).write(to: shard)
        #expect(try ChatAttachmentPersistence.loadMessageTimes(forSessionID: id.uuidString, from: root).isEmpty)

        let timing = terminalTiming()
        let thread = ChatThread(id: id, messages: [
            ChatMessageUI(role: .user, content: "问"),
            ChatMessageUI(role: .assistant, content: "答", turnTiming: timing,
                          turnProviderName: "Provider 甲", turnModelID: "model-x-2026"),
        ])
        try ChatAttachmentPersistence.save(sessions: [thread], to: root)
        let records = try #require(try ChatAttachmentPersistence.load(from: root)[id.uuidString])
        let reopened = ChatAttachmentPersistence.restoreAttachments(from: thread.asPersisted(), records: records)
        #expect(reopened.messages[0].hasUnverifiedTimestamp)
        #expect(reopened.messages[1].timestamp == timing.startedAt)
        #expect(!reopened.messages[1].hasUnverifiedTimestamp)
    }
}
