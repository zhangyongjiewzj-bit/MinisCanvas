import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// 第二批线 R-3b：对话内“任务运行时保持唤醒”开关（RED）。对照 CC set_setting 的 keep_awake_while_working。
//
// 接口约定：键 resident.keep-awake，toggle，entries.agentMutable = true；revision 同 preferencesRevision
// （见 Batch2R_ConversationNotificationSwitchTests）。效果 = ResidentLifecycleController.keepAwakeDuringWork 赋值
// （设置页 ResidentSettingsSection.swift:19 同一属性，会写 resident.keepAwakeDuringWork 并重算断言）。
// 不含“登录时启动”：目录里不得出现任何 launch-at-login 键。
//
// 需要注入点（本文件唯一的新符号 → 编译级 RED）：ResidentLifecycleController.shared 用 UserDefaults.standard，
// 生产代码没有注入口。约定新增 `SettingsCenter.residentLifecycle: ResidentLifecycleController?`
// （与 SettingsCenter.swift:559 的 systemNotifications 并列，MinisCanvasApp.swift:~1395 装配时赋 .shared），
// 对话执行器只经它读写。测试注入隔离的控制器，绝不碰真实偏好与电源断言。
// 最小改动点：SettingsCenter.swift:559 旁加属性；ConversationSettingsToolExecutor.swift 目录读分支追加值/条目；
//   BL6SettingsCenterDispatch.swift:102-131 增 resident. 前缀分流。受影响现有测试：无。

@Suite("Batch2R conversation keep-awake switch", .serialized)
@MainActor
struct Batch2R_ConversationKeepAwakeTests {
    private func makeResident() throws -> (ResidentLifecycleController, UserDefaults, String) {
        let name = "batch2r-resident-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let controller = ResidentLifecycleController(
            defaults: defaults, createAssertion: { (0, 1) },
            releaseAssertion: { _ in 0 }, backgroundHasRunning: { false })
        return (controller, defaults, name)
    }

    @Test("a model switches keep-awake exactly like the Settings page toggle; the persisted preference follows")
    func keepAwakeWritesLikeSettingsPage() async throws {
        let fx = try await Batch2RFixture.make()
        defer { fx.cleanup() }
        let (resident, defaults, name) = try makeResident()
        defer { defaults.removePersistentDomain(forName: name) }
        fx.center.residentLifecycle = resident
        #expect(resident.keepAwakeDuringWork)

        let catalog = try await fx.readCatalog()
        #expect(catalog.values["resident.keep-awake"] == .toggle(true))
        #expect(catalog.isAgentMutable("resident.keep-awake") == true)
        #expect(catalog.entryIDs(prefix: "resident.").allSatisfy { !$0.contains("launch") })
        let revision = try #require(catalog.revision("preferencesRevision"))

        let write = try await fx.write(["resident.keep-awake": Batch2RFixture.toggle(false)], revision: revision)
        #expect(!write.toolFailed)
        #expect(await fx.approval.settingsRequests.count == 1)
        #expect(resident.keepAwakeDuringWork == false)
        let reloaded = ResidentLifecycleController(
            defaults: defaults, createAssertion: { (0, 1) },
            releaseAssertion: { _ in 0 }, backgroundHasRunning: { false })
        #expect(reloaded.keepAwakeDuringWork == false)
        let after = try await fx.readCatalog()
        #expect(after.values["resident.keep-awake"] == .toggle(false))
    }

    @Test("denying the keep-awake card leaves the preference as it was")
    func deniedKeepAwakeChangesNothing() async throws {
        let fx = try await Batch2RFixture.make(denying: [BL6SettingsToolApproval.toolName])
        defer { fx.cleanup() }
        let (resident, defaults, name) = try makeResident()
        defer { defaults.removePersistentDomain(forName: name) }
        fx.center.residentLifecycle = resident
        let revision = try #require(try await fx.readCatalog().revision("preferencesRevision"))

        let write = try await fx.write(["resident.keep-awake": Batch2RFixture.toggle(false)], revision: revision)
        #expect(await fx.approval.settingsRequests.count == 1)
        #expect(write.toolFailed)
        #expect(resident.keepAwakeDuringWork)
    }
}
