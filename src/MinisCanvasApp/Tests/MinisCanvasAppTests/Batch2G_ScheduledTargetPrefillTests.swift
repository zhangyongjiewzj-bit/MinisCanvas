import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Batch2G RED 1：定时任务“为此会话创建”。
/// 现状：新建表单要用户手填目标 Session UUID / Project ID / Turn ID，后两者界面无来源
/// （SchedulerTaskStore.swift:87 hasValidTarget 三者都要）。期望：ChatStore 能按会话给出预填目标，
/// 会话右键菜单有入口。
/// 需要新符号：`ChatStore.schedulerTaskTargetPrefill(forSessionID:) -> SchedulerTaskTargetPrefill?`
/// （字段 sessionID: UUID、projectID: String、turnID: Int）。turnID 取该会话最近一条用户消息的
/// 从 1 开始的用户轮次序号，与 `schedulerSourceAnchorDigest(... ordinal:)` 同口径。
@Suite("Batch2G scheduler target prefill from session", .serialized)
@MainActor
struct Batch2G_ScheduledTargetPrefillTests {
    @Test("prefill from a session yields a target that hasValidTarget and resolves a source anchor")
    func prefillFromSessionIsValidExecutableTarget() throws {
        let f = try ScheduledTargetFixture()   // 目标会话 3 条用户消息 + 3 条助手消息，项目 scheduled-project
        defer { f.cleanup() }
        let prefill = try #require(f.chat.schedulerTaskTargetPrefill(forSessionID: f.targetID))
        #expect(prefill.sessionID == f.targetID)
        #expect(prefill.projectID == f.projectID)
        #expect(prefill.turnID == 3)

        let task = SchedulerTask(
            name: "prefilled", cronExpression: "0 9 * * *", command: "/compact",
            targetSessionID: prefill.sessionID, targetProjectID: prefill.projectID,
            targetTurnID: prefill.turnID
        )
        #expect(task.hasValidTarget)
        // 预填的回合必须能在生产解析器里生成来源锚点，否则预览仍无法授权。
        #expect(f.chat.schedulerSourceAnchorDigest(
            sessionID: prefill.sessionID, projectID: prefill.projectID, ordinal: prefill.turnID) != nil)
    }

    @Test("prefill follows the requested session, not the active one")
    func prefillIsKeyedByRequestedSession() throws {
        let f = try ScheduledTargetFixture()
        defer { f.cleanup() }
        #expect(f.chat.activeSessionID == f.activeID)
        let prefill = try #require(f.chat.schedulerTaskTargetPrefill(forSessionID: f.targetID))
        #expect(prefill.sessionID == f.targetID)
        #expect(prefill.projectID == "scheduled-project")
    }

    @Test("session context menu offers 为此会话创建定时任务 next to 复制会话 ID")
    func sessionContextMenuHasCreateScheduledTaskEntry() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift"),
            encoding: .utf8)
        #expect(source.contains("为此会话创建定时任务"))
    }
}
