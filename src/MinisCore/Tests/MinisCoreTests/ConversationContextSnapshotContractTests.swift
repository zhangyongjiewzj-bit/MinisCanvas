import Foundation
import Testing
@testable import MinisCore

/// P3-A4-CONTEXT-CONTRACT-R1：会话级上下文快照 DTO 契约（RED 先行）。
///
/// 契约点：
/// 1. 不可变：全部属性为 `let` 的值类型，`Sendable` + `Codable`；
///    JSON 往返必须无损保留全部绑定事实与快照 ID。
/// 2. 跨会话 / 跨 provider / 跨技能不匹配一律拒绝（`matches == false`）。
/// 3. 快照 ID 漂移（声明 ID 与规范派生 ID 不一致）fail closed：
///    漂移快照连自身都不匹配。
/// 4. 快照 ID 冲突（同一快照 ID 对应两份不同内容）拒绝。
/// 5. 规范快照 ID 稳定：相同绑定事实构造出的快照 ID 恒等。
struct ConversationContextSnapshotContractTests {

    private func makeSnapshot(
        snapshotID: String? = nil,
        sessionID: String = "session-a",
        providerID: String = "provider-a",
        modelID: String = "model-a",
        configurationFingerprint: String = "fp-a",
        skillIdentifiers: [String] = ["file_read", "browser"],
        conversationID: String? = "conversation-a"
    ) -> ConversationContextSnapshotV1 {
        ConversationContextSnapshotV1(
            snapshotID: snapshotID,
            sessionID: sessionID,
            providerID: providerID,
            modelID: modelID,
            configurationFingerprint: configurationFingerprint,
            skillIdentifiers: skillIdentifiers,
            conversationID: conversationID
        )
    }

    // MARK: - 不可变 / Codable / Sendable

    @Test func snapshotIsImmutableSendableCodableValueType() {
        let base = makeSnapshot()
        // Sendable 编译期证明：快照可在 @Sendable 闭包间无竞争传递。
        let sendableCapture: @Sendable () -> ConversationContextSnapshotV1 = { base }
        let captured = sendableCapture()
        #expect(captured == base)
        // 值类型：两次独立构造语义相等（非引用同一实例）。
        #expect(makeSnapshot() == base)
    }

    @Test func snapshotCodableRoundTripPreservesAllBindingFacts() throws {
        let base = makeSnapshot(
            sessionID: "session-1",
            providerID: "provider-1",
            modelID: "model-1",
            configurationFingerprint: "fp-1",
            skillIdentifiers: ["skill-a", "skill-b", "skill-c"],
            conversationID: "conversation-1"
        )
        let data = try JSONEncoder().encode(base)
        let decoded = try JSONDecoder().decode(ConversationContextSnapshotV1.self, from: data)
        #expect(decoded == base)
        #expect(decoded.snapshotID == base.snapshotID)
        #expect(decoded.sessionID == "session-1")
        #expect(decoded.providerID == "provider-1")
        #expect(decoded.modelID == "model-1")
        #expect(decoded.configurationFingerprint == "fp-1")
        #expect(decoded.skillIdentifiers == ["skill-a", "skill-b", "skill-c"])
        #expect(decoded.conversationID == "conversation-1")
    }

    // MARK: - 规范快照 ID 稳定

    @Test func snapshotIDIsStableAcrossIdenticalContent() {
        let a = makeSnapshot()
        let b = makeSnapshot()
        #expect(a.snapshotID == b.snapshotID)
        #expect(a.snapshotID.hasPrefix("context:"))
        #expect(a.matches(b))
        #expect(b.matches(a))
    }

    // MARK: - 跨会话 / 跨 provider / 跨技能不匹配拒绝

    @Test func matchesRejectsCrossSessionMismatch() {
        let base = makeSnapshot()
        let other = makeSnapshot(sessionID: "session-b")
        #expect(base.matches(other) == false)
        #expect(other.matches(base) == false)
    }

    @Test func matchesRejectsCrossProviderMismatch() {
        let base = makeSnapshot()
        let other = makeSnapshot(providerID: "provider-b")
        #expect(base.matches(other) == false)
    }

    @Test func matchesRejectsCrossSkillMismatch() {
        let base = makeSnapshot(skillIdentifiers: ["skill-a", "skill-b"])
        let other = makeSnapshot(skillIdentifiers: ["skill-a", "skill-c"])
        #expect(base.matches(other) == false)
        #expect(other.matches(base) == false)
    }

    // MARK: - 快照 ID 漂移 fail closed

    @Test func matchesRejectsSnapshotIDDriftFailClosed() {
        let clean = makeSnapshot()
        // 显式传入与规范派生 ID 不一致的 ID —— 伪造/漂移快照。
        let drifted = makeSnapshot(snapshotID: "context:forged:drifted")
        #expect(drifted.snapshotID != drifted.canonicalSnapshotID())
        // 漂移快照连自身都不匹配（fail closed）。
        #expect(drifted.matches(drifted) == false)
        #expect(clean.matches(drifted) == false)
        #expect(drifted.matches(clean) == false)
    }

    // MARK: - 快照 ID 冲突拒绝（同 ID 不同内容）

    @Test func matchesRejectsSnapshotIDConflictSameIDDifferentContent() {
        // 技能顺序不同 → 规范 ID 相同（ID 由排序后技能派生），但内容数组不同。
        let a = makeSnapshot(skillIdentifiers: ["skill-a", "skill-b"])
        let b = makeSnapshot(skillIdentifiers: ["skill-b", "skill-a"])
        #expect(a.snapshotID == b.snapshotID) // 同一快照 ID
        #expect(a != b) // 内容不同 → 冲突
        #expect(a.matches(b) == false) // 冲突拒绝
        #expect(b.matches(a) == false)
    }
}
