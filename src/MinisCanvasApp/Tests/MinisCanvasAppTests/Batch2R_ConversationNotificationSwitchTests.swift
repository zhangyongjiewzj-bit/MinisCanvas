import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// 第二批线 R-3：对话内通知分类开关（RED）。对照 CC set_setting 的 permission_request/question/task_complete 通知键。
//
// 接口约定（复用 conversation_settings）：
//   键 notifications.approvals / notifications.tasks，toggle，entries.agentMutable = true，
//   值取自 SettingsCenter.systemNotifications（设置页 SystemNotificationSettingsSection.swift:8 同一个控制器）。
//   catalog 新增顶层 preferencesRevision，写入 expectedRevision 取它（通知与“保持唤醒”共用一把）。
//   效果 = SystemNotificationController.setEnabled(category, value)；只切分类开关，不申请系统授权
//   （isRequesting 仍 false、authorizationStatus 仍 .unknown）。每次写入弹审批卡。
//   不含“登录时启动”（登录项属系统设置且需签名，见 26 号）。
// 最小改动点：ConversationSettingsToolExecutor.swift 目录读分支追加 notifications.* 值/条目与 preferencesRevision；
//   BL6SettingsCenterDispatch.swift:102-131 增 notifications. 前缀分流 → center.systemNotifications?.setEnabled。
// 受影响的现有测试：无（新增键）。

@Suite("Batch2R conversation notification switches", .serialized)
@MainActor
struct Batch2R_ConversationNotificationSwitchTests {
    @Test("a model flips a notification category exactly like the Settings page toggle, without asking the system for permission",
          arguments: ["approvals", "tasks"])
    func categorySwitchWritesLikeSettingsPage(_ raw: String) async throws {
        let fx = try await Batch2RFixture.make()
        defer { fx.cleanup() }
        let category = try #require(SystemNotificationCategory(rawValue: raw))
        let key = "notifications.\(raw)"
        #expect(fx.notifications.isEnabled(category) == false)

        let catalog = try await fx.readCatalog()
        #expect(catalog.values[key] == .toggle(false))
        #expect(catalog.isAgentMutable(key) == true)
        let revision = try #require(catalog.revision("preferencesRevision"))

        let write = try await fx.write([key: Batch2RFixture.toggle(true)], revision: revision)
        #expect(!write.toolFailed)
        #expect(await fx.approval.settingsRequests.count == 1)
        #expect(fx.notifications.isEnabled(category))
        #expect(fx.notifications.isRequesting == false)
        #expect(fx.notifications.authorizationStatus == .unknown)
        // 与设置页同一份持久化：重建控制器后仍是开。
        let reloaded = SystemNotificationController(
            defaults: fx.notificationDefaults, canUseSystemNotifications: false)
        #expect(reloaded.isEnabled(category))

        let after = try await fx.readCatalog()
        #expect(after.values[key] == .toggle(true))
    }

    @Test("denying the notification switch card changes nothing, in memory or on disk",
          arguments: ["approvals", "tasks"])
    func deniedSwitchChangesNothing(_ raw: String) async throws {
        let fx = try await Batch2RFixture.make(denying: [BL6SettingsToolApproval.toolName])
        defer { fx.cleanup() }
        let category = try #require(SystemNotificationCategory(rawValue: raw))
        let revision = try #require(try await fx.readCatalog().revision("preferencesRevision"))

        let write = try await fx.write(["notifications.\(raw)": Batch2RFixture.toggle(true)],
                                       revision: revision)
        #expect(await fx.approval.settingsRequests.count == 1)
        #expect(write.toolFailed)
        #expect(fx.notifications.isEnabled(category) == false)
        #expect(SystemNotificationController(
            defaults: fx.notificationDefaults, canUseSystemNotifications: false)
            .isEnabled(category) == false)
    }

    @Test("a stale preferencesRevision is refused and the switch stays as it was")
    func staleRevisionRefused() async throws {
        let fx = try await Batch2RFixture.make()
        defer { fx.cleanup() }
        let revision = try #require(try await fx.readCatalog().revision("preferencesRevision"))
        // 用户在设置页先改了一个分类，模型手里的 revision 已过期。
        fx.notifications.setEnabled(.approvals, true)

        let write = try await fx.write(["notifications.tasks": Batch2RFixture.toggle(true)],
                                       revision: revision)
        #expect(write.toolFailed)
        #expect(fx.notifications.isEnabled(.tasks) == false)
        #expect(fx.notifications.isEnabled(.approvals))
    }

    // MARK: 低优（报告 26 号第五节列为低优；接口不清则保持禁用，修复作者可先不做）

    @Test("conversation can add and remove only disabled user hooks")
    func hooksAddRemoveStaysUntrusted() async throws {
        let fx = try await Batch2RFixture.make(scope: .session)
        defer { fx.cleanup() }
        let directory = fx.root.appendingPathComponent("settings/hooks", isDirectory: true)
        let store = HookConfigStore(directory: directory)
        fx.center.conversationHookStore = store
        let catalog = try await fx.readCatalog()
        let hooksRevision = catalog.json["hooksRevision"] as? String
        #expect(hooksRevision != nil)
        let revision = try hooksRevision ?? fx.ordinaryCatalogRevision()
        let fields = ["id": Batch2RFixture.text("batch2r-hook"),
                      "event": Batch2RFixture.text("SessionStart"),
                      "command": Batch2RFixture.text("true")]
        var enabled = fields
        enabled["enabled"] = Batch2RFixture.toggle(true)
        let denied = try await fx.write(["hooks.entries.add": Batch2RFixture.object(enabled)], revision: revision)
        #expect(denied.toolFailed)
        let added = try await fx.write(["hooks.entries.add": Batch2RFixture.object(fields)], revision: revision)
        #expect(!added.toolFailed)
        let reopened = HookConfigStore(directory: directory)
        let snapshot = reopened.userHooksSnapshot()
        #expect(snapshot.hooks == [HookDefinition(id: "batch2r-hook", event: .sessionStart,
                                                command: "true", enabled: false)])
        try #require(snapshot.executableHooks.isEmpty)
        let runtime = HookRuntime(store: reopened)
        _ = await runtime.beginTurn(sessionID: "batch2r-hook-check", prompt: "synthetic", projectRoot: nil)
        #expect(runtime.recentRuns().isEmpty)
        let remove = ["hooks.entries.remove": Batch2RFixture.object(["id": Batch2RFixture.text("batch2r-hook")])]
        let stale = try await fx.write(remove, revision: revision)
        #expect(stale.toolFailed)
        let updated = try await fx.readCatalog()
        let updatedHooksRevision = updated.json["hooksRevision"] as? String
        #expect(updatedHooksRevision != nil)
        let updatedRevision = try updatedHooksRevision ?? fx.ordinaryCatalogRevision()
        #expect(updatedRevision != revision)
        #expect(catalog.isAgentMutable("hooks.entries.add") == true)
        #expect(catalog.isAgentMutable("hooks.entries.remove") == true)
        #expect(!updated.body.contains("batch2r-hook"))
        let duplicate = try await fx.write(["hooks.entries.add": Batch2RFixture.object(fields)], revision: updatedRevision)
        #expect(duplicate.toolFailed)
        let unknown = fields.merging(["source": Batch2RFixture.text("project")]) { _, new in new }
        let project = try await fx.write(["hooks.entries.add": Batch2RFixture.object(unknown)], revision: updatedRevision)
        #expect(project.toolFailed)
        let removed = try await fx.write(remove, revision: updatedRevision)
        #expect(!removed.toolFailed)
        #expect(HookConfigStore(directory: directory).loadUserHooks().hooks.isEmpty)

        try store.addUserHook(HookDefinition(id: "native-enabled", event: .sessionStart, command: "true"))
        let nativeCatalog = try await fx.readCatalog()
        let nativeRevision = try #require(nativeCatalog.revision("hooksRevision"))
        let active = try await fx.write(
            ["hooks.entries.remove": Batch2RFixture.object(["id": Batch2RFixture.text("native-enabled")])],
            revision: nativeRevision)
        #expect(active.toolFailed)
        #expect(HookConfigStore(directory: directory).loadUserHooks().hooks.first?.enabled == true)
        let approvals = await fx.approval.settingsRequests
        #expect(approvals.count == 7)
        #expect(Set(approvals.map(\.requestID)).count == approvals.count)
    }

    @Test("conversation cannot restore executable trust by removing a disabled hook")
    func hooksCannotRevivePreviouslyTrustedEnabledEntries() async throws {
        let fx = try await Batch2RFixture.make()
        defer { fx.cleanup() }
        let directory = fx.root.appendingPathComponent("settings/hooks", isDirectory: true)
        let store = HookConfigStore(directory: directory)
        fx.center.conversationHookStore = store
        let existing = HookDefinition(id: "native-enabled", event: .sessionStart, command: "true")
        try store.addUserHook(existing)
        let trustedHash = try #require(store.userHooksSnapshot().contentHash)
        try store.trustUserHooks(expectedHash: trustedHash)
        try #require(store.userHooksSnapshot().executableHooks == [existing])

        let catalog = try await fx.readCatalog()
        let revision = try #require(catalog.revision("hooksRevision"))
        let fields = ["id": Batch2RFixture.text("disabled"),
                      "event": Batch2RFixture.text("SessionStart"),
                      "command": Batch2RFixture.text("true")]
        let added = try await fx.write(["hooks.entries.add": Batch2RFixture.object(fields)], revision: revision)
        try #require(!added.toolFailed)
        let changed = store.userHooksSnapshot()
        try #require(changed.executableHooks.isEmpty && changed.hooks.count == 2)

        let updated = try await fx.readCatalog()
        let updatedRevision = try #require(updated.revision("hooksRevision"))
        let remove = ["hooks.entries.remove": Batch2RFixture.object(["id": Batch2RFixture.text("disabled")])]
        let rejected = try await fx.write(remove, revision: updatedRevision)
        #expect(rejected.toolFailed)
        let reopened = HookConfigStore(directory: directory).userHooksSnapshot()
        #expect(reopened.hooks == changed.hooks)
        #expect(reopened.executableHooks.isEmpty)
        #expect(reopened.contentHash == changed.contentHash)
    }

    @Test("[低优] entering plan mode is allowed through composer.mode-lower, only the value plan",
          .disabled("低优，待定：新增 composer.mode-lower 键（仅可取 plan）；沿用 conversation_settings 的审批卡也可"))
    func enteringPlanModeIsLowerOnly() async throws {
        let fx = try await Batch2RFixture.make()
        defer { fx.cleanup() }
        let revision = try fx.ordinaryCatalogRevision()
        _ = try await fx.write(["composer.mode-lower": Batch2RFixture.text("plan")], revision: revision)
        #expect(fx.chat.composerPolicySelection.mode == .plan)
        let escalate = try await fx.write(["composer.mode-lower": Batch2RFixture.text("auto")], revision: revision)
        #expect(escalate.toolFailed)
    }
}
