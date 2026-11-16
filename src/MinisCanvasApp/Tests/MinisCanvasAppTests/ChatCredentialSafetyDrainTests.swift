import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// MARK: - W5-CRED-STOPALL-FINISH-052：Kill Switch fallback 的凭据终态契约
//
// 缺陷来源：W4-CRED-TERM-SCRUB-034 回执 `escalations.observations_for_lane_031_PKG_MAIN`
// 记录 ChatStore `stopAllStreamingForSafety` 的 fallback 分支——当会话没有
// `activeWritebackIdentities` 条目、或 messageID 非 UUID 时，只用裸 `content +=`
// 收尾，从不让凭据 broker 到达终态 ⇒ Kill Switch 停全流后，该路径上的原始
// （未掩码）流式累积副本仍在 broker 内存存活，可在下一次投影时复活明文。
// 本轮另外核实出同一 sweep 的第二个同型出口：`finalizeStreamingMessage` 的
// `finishStream` 位于它的 guard 之后，guard 拒绝（会话/消息已不可寻址）时
// broker 副本同样不被终止，而且气泡会永远停在「生成中」。
//
// 需求归属沿用 034 的如实映射：P3-CRED-01（明细 D-CREDH cancel/timeout custody、
// D-CREDI transcript/export no-secret）。`CRED-TERM-SCRUB` 与本 lane 的
// `CRED-STOPALL-FINISH` 都是 C0 残留名，不是表内 ID，此处不新造编号。
//
// RED→GREEN 判别口径（详见回执 `pkg_replay_assertions`）：
// · `missingWritebackIdentity…`、`nonUUIDWritebackIdentity…`：修复前 drain 之后
//   再投影同一 messageID，broker 里幸存的原始副本会把明文重新暴露，
//   `rebuilt == "干净后续 next"` 不成立 → RED；修复后 GREEN。
// · `finalizerRejection…`：修复前 guard 拒绝后既不 finishStream 也不收尾气泡，
//   `isStreaming == false` 与 orphan 副本的 `rebuilt` 断言双双不成立 → RED。
// · `identityPath…`、`fallbackTerminalState…`、`settleAllIsIdempotent…` 是不变量
//   钉桩（主路径终态唯一、fallback 不新增落盘暴露、重复 drain 幂等），
//   修复前后都应为 GREEN，用来证明这次收紧没有把行为改宽。
//
// 凭据样例全部是合成不透明标记（`SYNTH-CREDSTOP-*` + 随机 UUID），不含任何真值。
// 之所以不用 `sk-` 形状：`ContentSecretRedactor` 会按通用模式无条件掩码 `sk-*`，
// 那样就测不出「只有托管 knownSecrets 才掩码」的不透明值在托管撤销后的复活路径
// （口径同 W4-CRED-TERM-SCRUB-034 的测试样例）。

@Suite("Kill Switch fallback reaches credential terminal state")
@MainActor
struct ChatCredentialSafetyDrainTests {

    /// 不透明合成凭据：不命中任何通用掩码模式，只有 broker 托管会掩码它。
    private func syntheticSecret(_ tag: String) -> String {
        "SYNTH-CREDSTOP-\(tag)-" + UUID().uuidString
    }

    /// 让 broker 托管合成值（`capture` 的赋值模式识别 `api_key=`）。
    private func seedCustody(
        _ chat: ChatStore, sessionID: UUID, secret: String, tag: String
    ) {
        let captured = chat.credentialBroker.capture("保存 api_key=\(secret)", sessionID: sessionID)
        #expect(!captured.contains(secret), "托管后 surface 不得含明文（\(tag)）")
        #expect(chat.credentialBroker.pending != nil, "托管必须建立（\(tag)）")
    }

    /// 判别器：drain 之后再对同一 messageID 投影。若 broker 仍握着那份原始
    /// 副本，返回值就会带上它（托管此时已撤销 ⇒ 明文复活）；终态做对了就只能
    /// 从传入文本重建。
    private func expectNoSurvivingRawCopy(
        _ chat: ChatStore, messageID: UUID, secret: String, tag: String
    ) {
        let rebuilt = chat.credentialBroker.projectStream(
            messageID: messageID, current: "干净后续", append: " next"
        )
        #expect(!rebuilt.contains(secret), "\(tag)：broker 原始副本在 Kill Switch 后仍存活")
        #expect(rebuilt == "干净后续 next", "\(tag)：投影必须从传入文本重建，而不是残留副本")
    }

    /// 造出 fallback 前置状态：会话里有一条 `isStreaming` 气泡，broker 的原始
    /// 流副本装着未掩码的合成凭据（surface 只留掩码），并有一个在跑的流任务，
    /// 但写回身份处于旧引擎形态。
    private func makeDrainFixture(
        writebackMessageID: String?,
        tag: String,
        dropCustodyBeforeDrain: Bool = true,
        persistingInto store: SessionStore? = nil
    ) throws -> (ChatStore, UUID, UUID, String) {
        let chat = ChatStore()
        if let store { #expect(chat.attachPersistence(store), "持久化装配必须成功（\(tag)）") }
        let sessionID = try #require(chat.activeSessionID)
        chat.appendAssistant("部分输出", toSession: sessionID, isStreaming: true)
        let bubbleID = try #require(chat.messages.last?.id)
        let secret = syntheticSecret(tag)
        seedCustody(chat, sessionID: sessionID, secret: secret, tag: tag)
        // 真实的无身份写回口（旧引擎形态）：把明文塞进 broker 原始副本。
        #expect(chat.updateMessageContent(
            sessionID: sessionID, at: chat.messages.count - 1, append: " 尾部 \(secret)"
        ))
        #expect(!(chat.messages.last?.content.contains(secret) ?? true))
        if dropCustodyBeforeDrain {
            // 撤销托管（凭据卡取消 / TTL 到期同款可达触发）：此后 protect 不再
            // 掩码，任何幸存原始副本都会在下一次投影时以明文复活。
            chat.credentialBroker.cancel()
            #expect(chat.credentialBroker.pending == nil)
        }
        chat.installLegacySafetyDrainStateForTests(writebackMessageID: writebackMessageID)
        return (chat, sessionID, bubbleID, secret)
    }

    // MARK: 1 缺失写回身份（034 escalation 点名的第一形态）

    @Test("缺失写回身份的 fallback 必须让 broker 到达 finish 终态")
    func missingWritebackIdentityFallbackTerminatesBrokerCustody() throws {
        let (chat, sessionID, bubbleID, secret) = try makeDrainFixture(
            writebackMessageID: nil, tag: "noidentity"
        )
        #expect(chat.activeWritebackIdentity(for: sessionID) == nil)
        #expect(chat.messages.last?.isStreaming == true)

        chat.stopAllStreamingForSafety()

        // fail-closed：气泡不能停在「生成中」，终态提示必须落。
        #expect(chat.messages.last?.isStreaming == false)
        #expect(chat.messages.last?.content.contains("已由安全锁终止") == true)
        #expect(chat.activeWritebackIdentity(for: sessionID) == nil)
        #expect(chat.hasStreamingTasksForSafety == false)
        #expect(chat.isStreaming == false)
        expectNoSurvivingRawCopy(chat, messageID: bubbleID, secret: secret, tag: "noidentity")
    }

    // MARK: 2 messageID 非 UUID（034 escalation 点名的第二形态）

    @Test("messageID 非 UUID 的 fallback 不得静默跳过凭据终止")
    func nonUUIDWritebackIdentityFallbackTerminatesBrokerCustody() throws {
        let legacyIdentity = "legacy-stream-not-a-uuid"
        let (chat, sessionID, bubbleID, secret) = try makeDrainFixture(
            writebackMessageID: legacyIdentity, tag: "nonuuid"
        )
        // 证明确实走了非 UUID 分支：身份在，但 messageID 解析不出 UUID。
        #expect(chat.activeWritebackIdentity(for: sessionID)?.messageID == legacyIdentity)
        #expect(UUID(uuidString: legacyIdentity) == nil)

        chat.stopAllStreamingForSafety()

        #expect(chat.messages.last?.isStreaming == false)
        #expect(chat.messages.last?.content.contains("已由安全锁终止") == true)
        #expect(chat.activeWritebackIdentity(for: sessionID) == nil)
        #expect(chat.hasStreamingTasksForSafety == false)
        expectNoSurvivingRawCopy(chat, messageID: bubbleID, secret: secret, tag: "nonuuid")
    }

    // MARK: 3 finalize guard 拒绝（合法 UUID 但消息已不可寻址）

    @Test("finalize 被 guard 拒绝时仍闭合气泡并终止凭据副本")
    func finalizerRejectionStillSettlesBubbleAndTerminatesCustody() throws {
        let chat = ChatStore()
        let sessionID = try #require(chat.activeSessionID)
        chat.appendAssistant("部分输出", toSession: sessionID, isStreaming: true)
        let bubbleIndex = chat.messages.count - 1
        let bubbleID = chat.messages[bubbleIndex].id
        let secret = syntheticSecret("orphanidentity")
        seedCustody(chat, sessionID: sessionID, secret: secret, tag: "orphanidentity")
        #expect(chat.updateMessageContent(
            sessionID: sessionID, at: bubbleIndex, append: " 尾部 \(secret)"
        ))
        // 一个不在转录里的合法 UUID：身份形状合法，但 finalize 的 guard 会拒绝。
        let orphanID = UUID()
        let rawCopy = chat.credentialBroker.projectStream(
            messageID: orphanID, current: "旧回合 ", append: secret
        )
        #expect(!rawCopy.contains(secret))
        chat.credentialBroker.cancel()
        chat.installLegacySafetyDrainStateForTests(writebackMessageID: orphanID.uuidString)
        #expect(chat.messages[bubbleIndex].isStreaming)

        chat.stopAllStreamingForSafety()

        // 判别：修复前 guard 拒绝后没人收尾，这条气泡永远显示「生成中」。
        #expect(chat.messages[bubbleIndex].isStreaming == false)
        #expect(chat.messages[bubbleIndex].content.contains("已由安全锁终止"))
        #expect(chat.hasStreamingTasksForSafety == false)
        // 判别：orphan 身份那份副本必须被终止；本轮同时补上气泡自己那份。
        expectNoSurvivingRawCopy(chat, messageID: orphanID, secret: secret, tag: "orphanidentity")
        expectNoSurvivingRawCopy(chat, messageID: bubbleID, secret: secret, tag: "orphanidentity-bubble")
    }

    // MARK: 4 主路径不变（防把收紧写成回归）

    @Test("合法 UUID 身份仍只走 finalize 主路径，终态提示只追加一次")
    func identityPathMainFinalizerRemainsSingleSuffix() throws {
        let chat = ChatStore()
        let sessionID = try #require(chat.activeSessionID)
        chat.appendAssistant("部分输出", toSession: sessionID, isStreaming: true)
        let bubbleIndex = chat.messages.count - 1
        let bubbleID = chat.messages[bubbleIndex].id
        let secret = syntheticSecret("mainpath")
        seedCustody(chat, sessionID: sessionID, secret: secret, tag: "mainpath")
        #expect(chat.updateMessageContent(
            sessionID: sessionID, at: bubbleIndex, append: " 尾部 \(secret)"
        ))
        // 托管保持有效：主路径 finalize 走 projectStream，掩码必须仍然生效。
        chat.installLegacySafetyDrainStateForTests(writebackMessageID: bubbleID.uuidString)
        #expect(chat.activeWritebackIdentity(for: sessionID)?.messageID == bubbleID.uuidString)

        chat.stopAllStreamingForSafety()

        let settled = chat.messages[bubbleIndex].content
        #expect(chat.messages[bubbleIndex].isStreaming == false)
        #expect(settled.hasSuffix("\n\n*⏹ 已由安全锁终止*"))
        #expect(
            settled.components(separatedBy: "已由安全锁终止").count - 1 == 1,
            "fallback 不得在主路径之后重复追加终态提示"
        )
        #expect(!settled.contains(secret))
        #expect(chat.hasStreamingTasksForSafety == false)
        expectNoSurvivingRawCopy(chat, messageID: bubbleID, secret: secret, tag: "mainpath")
    }

    // MARK: 5 fallback 收尾的落盘面不得出现明文

    @Test("fallback 终态写盘后转录与磁盘原始字节仍没有明文凭据")
    func fallbackTerminalStateKeepsDurableTranscriptSecretFree() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("W5-052-safety-drain-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let (chat, sessionID, bubbleID, secret) = try makeDrainFixture(
            writebackMessageID: nil, tag: "durable", persistingInto: store
        )

        chat.stopAllStreamingForSafety()

        // attachPersistence 把 onSessionsChanged 接到同步 persistSessions，
        // drain 的 touchSession 必须把 fallback 终态写盘（口径同 D-RECOVERY-10）。
        let reopened = try #require(
            SessionStore(directory: directory).loadSession(id: sessionID.uuidString)
        )
        #expect(reopened.messages.last?.content.contains("已由安全锁终止") == true)
        #expect(reopened.messages.allSatisfy { !$0.content.contains(secret) })
        let raw = try Data(
            contentsOf: store.sessionsDirectory.appendingPathComponent(sessionID.uuidString + ".json")
        )
        #expect(!(String(data: raw, encoding: .utf8)?.contains(secret) ?? false))
        // 内存侧同一契约：不因为「先释放 broker 再收尾文本」这个顺序把明文带回 surface。
        #expect(!(chat.messages.last?.content.contains(secret) ?? true))
        expectNoSurvivingRawCopy(chat, messageID: bubbleID, secret: secret, tag: "durable")
    }

    // MARK: 6 重复 drain 幂等（不新增旁路、不二次追加）

    @Test("安全锁重复触发不会重复收尾也不复活凭据副本")
    func repeatedSafetyDrainIsIdempotent() throws {
        let (chat, sessionID, bubbleID, secret) = try makeDrainFixture(
            writebackMessageID: nil, tag: "idempotent"
        )
        chat.stopAllStreamingForSafety()
        let firstTerminal = chat.messages.last?.content

        chat.stopAllStreamingForSafety()

        #expect(chat.messages.last?.content == firstTerminal)
        #expect(
            (chat.messages.last?.content.components(separatedBy: "已由安全锁终止").count ?? 0) - 1 == 1
        )
        #expect(chat.messages.last?.isStreaming == false)
        #expect(chat.hasStreamingTasksForSafety == false)
        #expect(chat.activeWritebackIdentity(for: sessionID) == nil)
        expectNoSurvivingRawCopy(chat, messageID: bubbleID, secret: secret, tag: "idempotent")
    }
}
