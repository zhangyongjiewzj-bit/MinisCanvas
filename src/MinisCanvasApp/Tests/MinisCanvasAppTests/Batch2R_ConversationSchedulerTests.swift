import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// 第二批线 R-2：对话内定时任务 启用/停用、创建、删除（RED）。对照 CC 定时任务工具。
//
// 接口约定（复用 conversation_settings，不另造工具）：
//   catalog 新增顶层字段 schedulerRevision（绑定了调度存储时恒存在；基于可见任务的 id/version/enablementRevision），
//   写入的 expectedRevision 取它。
//   启停  changes["scheduler.<uuid>.enabled"] = toggle      该键 entries.agentMutable 改为 true；
//         效果 = store.setEnabled(id, enabled:, expectedVersion: task.version, expectedEnablementRevision: …)，
//         与设置页开关（SchedulerControlSettingsView.swift:849）同一条路径。
//         authorized / name / cron-expression 仍 agentMutable:false（授权只能用户在设置页“授权预览+确认”点）。
//   创建  changes["scheduler.tasks.add"] = object{name:text, cron-expression:text, command:text}
//         目标会话/项目/回合 = ChatStore.schedulerTaskTargetPrefill(forSessionID: 当前会话)（线 G 已加）；
//         没有项目或还没有用户回合 → 失败不写入。效果 = store.add(...)，新任务 isAuthorized 恒为 false（与设置页新建一致），
//         之后由用户在设置页走“授权预览→确认”。bypass 模式也不继承授权。
//   删除  changes["scheduler.tasks.remove"] = object{id:text(任务 uuid)}
//         仅限目标是当前会话+项目的任务（与 snapshotVisible 同一可见性）。效果 = 与 SchedulerTaskDeletionConsumer.confirm
//         相同的 tombstone（isDeleted、version+1）。
//   审批卡：每次都弹（含 bypass、含范围同意之后），卡文案含任务名；创建卡含 名称/cron/命令全文。
//
// 最小改动点：
//   ConversationSettingsToolExecutor.swift:349 把 scheduler 的 enabled 行 agentMutable 改 true，并追加 schedulerRevision 与两个
//     scheduler.tasks.* 条目（同 mcp.servers.* 的 :258-263 写法）；
//   BL6SettingsCenterDispatch.swift:102-131 增 schedulerEnablementApply/schedulerTaskApply 分流（:1319-1489 处补分支），
//     调用 SchedulerTaskStore.setEnabled/add/delete；SchedulerStoreTypedCatalogAdapter.swift:101 的 preview 可复用做 enabled 校验；
//   ComposerApprovalPolicy.swift:1143/:1198/:1248 把 isMCPServerManagement 扩成含 scheduler.tasks.*（每次必问，不记范围同意）；
//   ApprovalGate.swift:~508 仿 mcpServerManagementSummary 写 schedulerSummary，并加 schedulerTaskDisplayName 解析器。
// 受影响的现有测试：ConversationSettingsProvider2094Tests（:1852 条目 agentMutable 全 false 的断言、
//   :1948 providerRejectsReadOnlyStoreMutation 对 target "scheduler" 的拒绝）。

@Suite("Batch2R conversation scheduler management", .serialized)
@MainActor
struct Batch2R_ConversationSchedulerTests {
    private func enabledKey(_ task: SchedulerTask) -> String {
        SchedulerStoreTypedCatalogAdapter.settingID(taskID: task.id, field: "enabled")
    }

    private func addChanges(name: String, cron: String = "0 9 * * *",
                            command: String = "总结昨天的会话并列出待办") -> [String: Any] {
        ["scheduler.tasks.add": Batch2RFixture.object([
            "name": Batch2RFixture.text(name),
            "cron-expression": Batch2RFixture.text(cron),
            "command": Batch2RFixture.text(command)
        ])]
    }

    private func removeChanges(id: UUID) -> [String: Any] {
        ["scheduler.tasks.remove": Batch2RFixture.object(["id": Batch2RFixture.text(id.uuidString)])]
    }

    // MARK: 启用 / 停用

    @Test("disable then enable through the conversation leaves the same task state as the Settings page switch, never authorizes")
    func toggleMatchesSettingsPage() async throws {
        let fx = try await Batch2RFixture.make()
        defer { fx.cleanup() }
        let viaChat = try fx.seedTask(name: "对话停用")
        let viaPage = try fx.seedTask(name: "界面停用")
        // 界面动作：设置页开关走的就是这一条（SchedulerControlSettingsView.swift:855）。
        #expect(fx.scheduler.setEnabled(viaPage.id, enabled: false, expectedVersion: viaPage.version,
                                        expectedEnablementRevision: viaPage.enablementRevision))
        let page = try #require(fx.scheduler.task(id: viaPage.id))

        let catalog = try await fx.readCatalog()
        #expect(catalog.isAgentMutable(enabledKey(viaChat)) == true)
        let revision = try #require(catalog.revision("schedulerRevision"))
        let off = try await fx.write([enabledKey(viaChat): Batch2RFixture.toggle(false)], revision: revision)
        #expect(!off.toolFailed)

        let stopped = try #require(fx.scheduler.task(id: viaChat.id))
        #expect(stopped.isEnabled == page.isEnabled)
        #expect(stopped.version == page.version)
        #expect(stopped.enablementRevision == page.enablementRevision)
        #expect(stopped.isAuthorized == false)
        let asked = await fx.approval.settingsRequests
        #expect(asked.count == 1)
        #expect(asked.first?.inputSummary.contains("对话停用") == true)

        let after = try await fx.readCatalog()
        #expect(after.values[enabledKey(viaChat)] == .toggle(false))
        let on = try await fx.write([enabledKey(viaChat): Batch2RFixture.toggle(true)],
                                    revision: try #require(after.revision("schedulerRevision")))
        #expect(!on.toolFailed)
        let resumed = try #require(fx.scheduler.task(id: viaChat.id))
        #expect(resumed.isEnabled)
        #expect(resumed.enablementRevision == stopped.enablementRevision + 1)
        // 启用不等于授权：授权位只能由用户在设置页“授权预览+确认”改。
        #expect(resumed.isAuthorized == false)
        #expect(await fx.approval.settingsRequests.count == 2)
    }

    @Test("denying the enable switch card leaves the task untouched")
    func deniedToggleChangesNothing() async throws {
        let fx = try await Batch2RFixture.make(denying: [BL6SettingsToolApproval.toolName])
        defer { fx.cleanup() }
        let task = try fx.seedTask(name: "拒绝启停")
        let revision = try #require(try await fx.readCatalog().revision("schedulerRevision"))

        let attempt = try await fx.write([enabledKey(task): Batch2RFixture.toggle(false)], revision: revision)
        #expect(await fx.approval.settingsRequests.count == 1)
        #expect(attempt.toolFailed)
        #expect(fx.scheduler.task(id: task.id) == task)
    }

    // MARK: 创建

    @Test("creating a task from the conversation targets the current session so it can be previewed and authorized in Settings")
    func createTaskTargetsCurrentSession() async throws {
        let fx = try await Batch2RFixture.make()
        defer { fx.cleanup() }
        let before = try await fx.readCatalog()
        let revision = try #require(before.revision("schedulerRevision"))

        let create = try await fx.write(addChanges(name: "每日早报"), revision: revision)
        #expect(create.requestCount == 2)
        #expect(!create.toolFailed)
        let receipt = try #require(create.returnedToolMessage)
        #expect((try? JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(receipt.utf8))) != nil)

        let created = fx.scheduler.allTasks().filter { $0.name == "每日早报" }
        #expect(created.count == 1)
        let task = try #require(created.first)
        let prefill = try #require(fx.chat.schedulerTaskTargetPrefill(forSessionID: fx.sessionID))
        #expect(task.cronExpression == "0 9 * * *")
        #expect(task.command == "总结昨天的会话并列出待办")
        #expect(task.isEnabled)
        #expect(task.targetSessionID == prefill.sessionID)
        #expect(task.targetProjectID == prefill.projectID)
        #expect(task.targetTurnID == prefill.turnID)
        #expect(task.hasValidTarget)
        #expect(task.isAuthorized == false)

        // 与设置页新建后的下一步一致：能出授权预览，且来源锚点可解析。
        let preview = try #require(fx.scheduler.preview(taskID: task.id))
        #expect(preview.hasValidTarget)
        #expect(preview.authorizationState == .waiting)
        #expect(fx.chat.schedulerSourceAnchorDigest(
            sessionID: prefill.sessionID, projectID: prefill.projectID, ordinal: prefill.turnID) != nil)

        let summary = try #require(await fx.approval.settingsRequests.first?.inputSummary)
        for shown in ["每日早报", "0 9 * * *", "总结昨天的会话并列出待办"] {
            #expect(summary.contains(shown), "创建卡缺少 \(shown)")
        }

        let after = try await fx.readCatalog()
        let prefix = "scheduler.\(task.id.uuidString.lowercased())"
        #expect(after.values["\(prefix).name"] == .text("每日早报"))
        #expect(after.values["\(prefix).enabled"] == .toggle(true))
        #expect(after.values["\(prefix).authorized"] == .toggle(false))
        #expect(after.revision("schedulerRevision") != revision)
    }

    @Test("denied create writes no task")
    func deniedCreateWritesNothing() async throws {
        let fx = try await Batch2RFixture.make(denying: [BL6SettingsToolApproval.toolName])
        defer { fx.cleanup() }
        let revision = try #require(try await fx.readCatalog().revision("schedulerRevision"))
        let create = try await fx.write(addChanges(name: "不应出现"), revision: revision)
        #expect(await fx.approval.settingsRequests.count == 1)
        #expect(create.toolFailed)
        #expect(fx.scheduler.allTasks().isEmpty)
    }

    @Test("a session without a project cannot get a task: nothing is written, no half-valid target")
    func createNeedsProjectSession() async throws {
        let fx = try await Batch2RFixture.make(project: false)
        defer { fx.cleanup() }
        #expect(fx.chat.schedulerTaskTargetPrefill(forSessionID: fx.sessionID) == nil)
        let revision = try #require(try await fx.readCatalog().revision("schedulerRevision"))
        let create = try await fx.write(addChanges(name: "无项目"), revision: revision)
        #expect(create.toolFailed)
        #expect(fx.scheduler.allTasks().isEmpty)
    }

    @Test("an invalid cron expression is rejected without writing")
    func createRejectsInvalidCron() async throws {
        let fx = try await Batch2RFixture.make()
        defer { fx.cleanup() }
        let revision = try #require(try await fx.readCatalog().revision("schedulerRevision"))
        let create = try await fx.write(addChanges(name: "坏表达式", cron: "61 * * * *"), revision: revision)
        #expect(create.toolFailed)
        #expect(fx.scheduler.allTasks().isEmpty)
    }

    @Test("confirmed bypass creates a task without a card and does not authorize it")
    func bypassCreateStillAsksAndNeverAuthorizes() async throws {
        let fx = try await Batch2RFixture.make(mode: .bypassPermission, bypassConfirmed: true)
        defer { fx.cleanup() }
        let revision = try #require(try await fx.readCatalog().revision("schedulerRevision"))
        let create = try await fx.write(addChanges(name: "绕过创建"), revision: revision)
        #expect(!create.toolFailed)
        #expect(await fx.approval.settingsRequests.isEmpty)
        let response = try #require(create.returnedToolMessage)
        let receipt = try JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(response.utf8))
        #expect(receipt.changedKeys == ["scheduler.tasks.add"])
        let task = try #require(fx.scheduler.allTasks().first { $0.name == "绕过创建" })
        #expect(task.isAuthorized == false)
    }

    // MARK: 删除

    @Test("deleting asks with the task name and tombstones the task like the Settings page delete")
    func deleteMatchesSettingsPage() async throws {
        let fx = try await Batch2RFixture.make()
        defer { fx.cleanup() }
        let viaChat = try fx.seedTask(name: "对话删除")
        let viaPage = try fx.seedTask(name: "界面删除")
        let request = try #require(SchedulerTaskDeletionConsumer.request(for: viaPage))
        #expect(SchedulerTaskDeletionConsumer.confirm(
            request, selectedTaskID: viaPage.id, store: fx.scheduler) == .deleted)
        let page = try #require(fx.scheduler.task(id: viaPage.id))

        let revision = try #require(try await fx.readCatalog().revision("schedulerRevision"))
        let delete = try await fx.write(removeChanges(id: viaChat.id), revision: revision)
        #expect(!delete.toolFailed)
        let asked = await fx.approval.settingsRequests
        #expect(asked.count == 1)
        #expect(asked.first?.inputSummary.contains("对话删除") == true)

        let tombstone = try #require(fx.scheduler.task(id: viaChat.id))
        #expect(tombstone.isDeleted == page.isDeleted)
        #expect(tombstone.version == viaChat.version + 1)
        #expect(tombstone.version == page.version)
        #expect(tombstone.isEnabled == false)
        #expect(!fx.scheduler.allTasks().contains { $0.id == viaChat.id })
        let after = try await fx.readCatalog()
        #expect(!after.values.keys.contains { $0.hasPrefix("scheduler.\(viaChat.id.uuidString.lowercased())") })
    }

    @Test("denied delete keeps the task")
    func deniedDeleteKeepsTask() async throws {
        let fx = try await Batch2RFixture.make(denying: [BL6SettingsToolApproval.toolName])
        defer { fx.cleanup() }
        let task = try fx.seedTask(name: "拒绝删除")
        let revision = try #require(try await fx.readCatalog().revision("schedulerRevision"))
        let delete = try await fx.write(removeChanges(id: task.id), revision: revision)
        #expect(await fx.approval.settingsRequests.count == 1)
        #expect(delete.toolFailed)
        #expect(fx.scheduler.task(id: task.id) == task)
    }

    @Test("a task that targets another session or project cannot be deleted from this conversation")
    func cannotDeleteOtherSessionTask() async throws {
        let fx = try await Batch2RFixture.make()
        defer { fx.cleanup() }
        let foreign = try fx.seedTask(name: "别处任务", session: UUID(), project: "other-project")
        let revision = try #require(try await fx.readCatalog().revision("schedulerRevision"))
        let delete = try await fx.write(removeChanges(id: foreign.id), revision: revision)
        #expect(delete.toolFailed)
        #expect(fx.scheduler.task(id: foreign.id) == foreign)
    }

    @Test("a session or workspace consent earned by an ordinary settings change never covers deleting a task",
          arguments: [ComposerApprovalScope.session, .workspace])
    func scopedConsentCannotCoverDelete(_ scope: ComposerApprovalScope) async throws {
        let fx = try await Batch2RFixture.make(scope: scope)
        defer { fx.cleanup() }
        let task = try fx.seedTask(name: "范围同意后删除")
        _ = try await fx.write(["general.language": Batch2RFixture.text("en")],
                               revision: try fx.ordinaryCatalogRevision())
        #expect(await fx.approval.settingsRequests.count == 1)

        let revision = try #require(try await fx.readCatalog().revision("schedulerRevision"))
        _ = try await fx.write(removeChanges(id: task.id), revision: revision)
        #expect(await fx.approval.settingsRequests.count == 2)
        #expect(fx.scheduler.task(id: task.id)?.isDeleted == true)
    }
}
