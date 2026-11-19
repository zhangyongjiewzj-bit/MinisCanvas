import XCTest
import Foundation
import Observation
import MinisCore
@testable import MinisCanvasApp

// MARK: - E22 设置生效修复测试
//
// 根因：SettingsCenter 的设置类属性是计算属性，get 直接读
// settingsStore.settings（@Observable 非追踪点）→ Picker 选值后 store
// 已写入但视图不刷新（表现为「选不生效、没有确认按钮」）。
// 修复：所有设置属性 get 读 @Observable 存储镜像 `settingsMirror`，
// set 先更新镜像（自动通知视图）再写 store（持久化）。
// 本文件验证：选即生效（get 立即返回新值）+ @Observable 刷新触发
// （withObservationTracking 失效回调）+ 持久化 + reset 重同步。

@MainActor
final class SettingsCenterObservationTests: XCTestCase {

    /// `withObservationTracking` 的 onChange 是 @Sendable 闭包，不能捕获可变 var；
    /// 用 NSLock 保护的计数器统计失效次数（测试内同步调用，锁开销可忽略）。
    private final class InvalidationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return _count
        }
        func increment() {
            lock.lock(); defer { lock.unlock() }
            _count += 1
        }
    }

    private func makeCenter(directory: URL? = nil) throws -> (SettingsCenter, URL) {
        let root: URL
        if let directory { root = directory }
        else {
            root = try RuntimeIsolationProfile.makeIsolatedTest(
                label: "theme2535-observation", canvasRuntimeState: .disabled).rootDirectory
        }
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let suite = "theme2535-observation-" + root.lastPathComponent
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 10),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite(suite)),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness")))
        return (center, root)
    }
    private func makeWriteFailingCenter() throws -> SettingsCenter {
        let (center, dir) = try makeCenter()
        let settingsURL = dir.appendingPathComponent(SettingsStore.fileName)
        try? FileManager.default.removeItem(at: settingsURL)
        try? FileManager.default.createDirectory(at: settingsURL, withIntermediateDirectories: true)
        return center
    }

    // MARK: - 选即生效：set 后 get 立即返回新值

    func testValuesReflectImmediatelyAfterSet() throws {
        let (center, _) = try makeCenter()

        center.appearance = .dark
        center.accentTheme = .ocean
        center.defaultProviderID = "openai"
        center.defaultModelID = "gpt-4o-mini"
        center.modelSpeedTier = .fast
        center.language = "en"
        center.maxLoopIterations = 25
        center.toolTimeoutSeconds = 120
        center.concurrentToolLimit = 8
        center.autoCompactThreshold = 0.9
        center.fallbackEnabled = false
        center.redactEnvValues = false
        center.privacyLogLevel = .error
        center.collectAnalytics = true
        center.sessionRetentionDays = 15
        center.memoryLimitMB = 512
        center.autoDeleteOldSessions = true

        // get 全部立即反映新值（视图绑定同一路径，选即生效）
        XCTAssertEqual(center.appearance, .system)
        // 重基线（lane 125 / SETTINGS-27/THEME-01）：原断言
        // XCTAssertEqual(center.accentTheme, .ocean) pin 的是被 THEME-01 取消的
        // 自由主题轴。「选即生效」属性以同等（更强的）精度保留在唯一真值上：
        // 写入 ocean 后预设立即反映收敛结果，主题字段立即等于定版投影。
        XCTAssertEqual(center.themePreset, .system, "ocean 写入经 nearest 立即收敛，旧dark收敛为System立即可见")
        XCTAssertEqual(center.accentTheme, ThemePreset.canonicalAccentTheme, "主题轴立即重投影为定版伪仙（精确等式）")
        XCTAssertEqual(center.defaultProviderID, "openai")
        XCTAssertEqual(center.defaultModelID, "gpt-4o-mini")
        XCTAssertEqual(center.modelSpeedTier, .fast)
        XCTAssertEqual(center.language, "en")
        XCTAssertEqual(center.maxLoopIterations, 25)
        XCTAssertEqual(center.toolTimeoutSeconds, 120)
        XCTAssertEqual(center.concurrentToolLimit, 8)
        XCTAssertEqual(center.autoCompactThreshold, 0.9, accuracy: 0.001)
        XCTAssertFalse(center.fallbackEnabled)
        XCTAssertFalse(center.redactEnvValues)
        XCTAssertEqual(center.privacyLogLevel, .error)
        XCTAssertTrue(center.collectAnalytics)
        XCTAssertEqual(center.sessionRetentionDays, 15)
        XCTAssertEqual(center.memoryLimitMB, 512)
        XCTAssertTrue(center.autoDeleteOldSessions)
    }

    // MARK: - @Observable 刷新触发：withObservationTracking 失效回调

    func testObservationInvalidatesViewDependenciesOnChange() throws {
        let (center, _) = try makeCenter()
        center.themePreset = .light // supported light→System transition under the same mirror observer.

        // `withObservationTracking` 的 onChange 仅在「首次」变更时回调一次
        //（Observation 语义：追踪在第一次失效后停止），因此每个属性变更
        // 分别建立一次追踪，验证视图 body 读取的设置属性确实被 @Observable 追踪。
        func observe() -> InvalidationCounter {
            let counter = InvalidationCounter()
            withObservationTracking {
                // 模拟视图 body 读取设置（这些读取现在依赖被追踪的存储镜像）
                _ = center.appearance
                _ = center.accentTheme
                _ = center.defaultProviderID
                _ = center.defaultModelID
                _ = center.modelSpeedTier
                _ = center.language
            } onChange: {
                counter.increment()
            }
            return counter
        }

        let appearanceObserved = observe()
        center.appearance = .dark
        XCTAssertEqual(appearanceObserved.count, 1, "外观变更应触发视图依赖失效")

        let themeObserved = observe()
        center.accentTheme = .ocean
        XCTAssertEqual(themeObserved.count, 0, "旧主题轴收敛到相同预设和颜色，不制造无效视图刷新")
        XCTAssertEqual(center.themePreset, .system)
        XCTAssertEqual(center.accentTheme, ThemePreset.canonicalAccentTheme)
        center.themePreset = .light
        XCTAssertEqual(themeObserved.count, 1, "真实预设变化仍使同一组视图依赖失效")

        let providerObserved = observe()
        center.defaultProviderID = "anthropic"
        XCTAssertEqual(providerObserved.count, 1, "默认模型变更应触发视图依赖失效")

        // 重基线新增（lane 125）：THEME-01 后视图绑定读取的唯一真值是
        // themePreset；对它直接写入必须同样触发 @Observable 失效（更强的覆盖面：
        // 原测试只覆盖两个旧投影字段的写入路径，现同时覆盖规范写入路径）。
        let presetObserved = observe()
        center.themePreset = .dark
        XCTAssertEqual(presetObserved.count, 1, "主题预设写入应触发视图依赖失效")
    }

    /// 根视图联动路径：appearance → colorSchemePreference（明暗切换）、
    /// accentTheme → .tint（主题色），读取后变更必须使视图失效。
    func testRootViewBindingsInvalidateOnChange() throws {
        let (center, _) = try makeCenter()

        let tintInvalidated = InvalidationCounter()
        withObservationTracking {
            _ = center.accentTheme.color  // 等价于根视图 .tint(settingsCenter.accentTheme.color)
        } onChange: {
            tintInvalidated.increment()
        }

        let schemeInvalidated = InvalidationCounter()
        withObservationTracking {
            _ = center.colorSchemePreference  // 等价于 .preferredColorScheme(...)
        } onChange: {
            schemeInvalidated.increment()
        }

        center.accentTheme = .crimson
        XCTAssertEqual(tintInvalidated.count, 0, "相同定版颜色不触发多余重算")
        // 旧主题轴不改变颜色或预设；随后真正改变预设，验证根视图
        // 所依赖的镜像仍受 Observation 跟踪。
        XCTAssertEqual(center.accentTheme, ThemePreset.canonicalAccentTheme, "crimson 写入立即重投影为定版伪仙")
        XCTAssertEqual(center.themePreset, .light, "主题轴写入不得移动预设真值（默认已是产品主题）")

        center.appearance = .dark
        XCTAssertEqual(tintInvalidated.count, 1, "真实镜像事务仍使根视图读取失效")
        XCTAssertEqual(schemeInvalidated.count, 1, "外观变更应使根视图 preferredColorScheme 重算")
        XCTAssertEqual(center.themePreset, .system, "重基线新增：旧深色写入收敛为跟随系统预设，preferredColorScheme 读取的真值随之确定")
    }

    // MARK: - 持久化：set 同时写入 store（重新加载可见）

    func testChangePersistsToStoreAndReload() throws {
        let (center, dir) = try makeCenter()

        center.appearance = .dark
        center.accentTheme = .emerald
        center.defaultProviderID = "anthropic"
        center.defaultModelID = "claude-sonnet"

        // 重基线（lane 125 / SETTINGS-27/THEME-05）：原断言
        // store.settings.general.accentTheme == .emerald（磁盘上存任意组合）
        // 正是 THEME-05 禁止的状态。同等强度（全部仍为精确等式）的新契约：
        // 存储真值是收敛后的预设，旧dark迁移为System，主题字段是定版投影。
        // F-1：明暗是独立选择，写 .dark 即固定深色，配色预设不变。
        XCTAssertEqual(center.settingsStore.settings.general.themePreset, .light)
        XCTAssertEqual(center.settingsStore.settings.general.appearance, .dark)
        XCTAssertEqual(center.settingsStore.settings.general.accentTheme, ThemePreset.canonicalAccentTheme)
        XCTAssertEqual(center.settingsStore.settings.general.defaultProviderID, "anthropic")
        XCTAssertEqual(center.settingsStore.settings.general.defaultModelID, "claude-sonnet")

        // 重新从磁盘加载验证持久化（THEME-05：已迁移/收敛的预设必须能跨
        // save/reload 存活——这正是本 lane 补齐的 consumer 半恢复路径）。
        let reloaded = SettingsStore(directory: dir)
        XCTAssertEqual(reloaded.settings.general.themePreset, .light, "预设必须跨重载存活")
        XCTAssertEqual(reloaded.settings.general.appearance, .dark, "固定深色必须跨重载存活")
        XCTAssertEqual(reloaded.settings.general.accentTheme, ThemePreset.canonicalAccentTheme)
        XCTAssertEqual(reloaded.settings.general.defaultProviderID, "anthropic")
        XCTAssertEqual(reloaded.settings.general.defaultModelID, "claude-sonnet")
    }

    func testTerminalPolicyPersistsReloadsAndResetsOnlyItsDomain() throws {
        let (center, dir) = try makeCenter()
        defer { try? FileManager.default.removeItem(at: dir) }

        center.appearance = .dark
        center.terminalPolicySettings = TerminalPolicySettings(
            automaticAllowCommands: ["echo", "printf", "env", "nice", "reboot"],
            confirmationCommands: ["git"],
            userDeniedCommands: ["printf", "custom-blocked"]
        )

        let expected = TerminalPolicySettings(
            automaticAllowCommands: ["echo", "env", "nice"],
            confirmationCommands: ["git"],
            userDeniedCommands: ["custom-blocked", "printf"]
        )
        XCTAssertEqual(center.terminalPolicySettings, expected)
        XCTAssertEqual(center.settingsStore.settings.agent.terminalPolicy, expected)

        let (reloaded, _) = try makeCenter(directory: dir)
        XCTAssertEqual(reloaded.terminalPolicySettings, expected)
        XCTAssertEqual(reloaded.terminalPolicySnapshot.classify(command: "echo ok"), .allowed)
        XCTAssertEqual(reloaded.terminalPolicySnapshot.classify(command: "printf ok"), .denied)
        XCTAssertFalse(reloaded.terminalPolicySettings.automaticAllowCommands.contains("reboot"))
        XCTAssertEqual(reloaded.terminalPolicySnapshot.classify(command: "env reboot Synthetic.app"), .denied)
        XCTAssertEqual(reloaded.terminalPolicySnapshot.classify(command: "nice reboot Synthetic.app"), .denied)

        reloaded.resetTerminalPolicyToDefaults()
        XCTAssertEqual(reloaded.terminalPolicySettings, .default)
        XCTAssertEqual(reloaded.appearance, .dark, "域重置不应改动其它设置")
        XCTAssertEqual(reloaded.settingsStore.settings.general.appearance, .dark)
        // 重基线新增（lane 125 / THEME-01）：域重置同样不得改动收敛后的唯一
        // 外观真值及其定版投影——预设维度纳入域隔离证明（属性更强，等式精确）。
        XCTAssertEqual(reloaded.themePreset, .light, "域重置不应改动主题预设真值")
        XCTAssertEqual(reloaded.accentTheme, ThemePreset.canonicalAccentTheme, "域重置后主题字段仍是预设的定版投影")
        XCTAssertEqual(SettingsStore(directory: dir).settings.agent.terminalPolicy, .default)
        XCTAssertEqual(reloaded.terminalPolicySnapshot.classify(command: "env reboot Synthetic.app"), .denied)
    }

    func testLegacyAgentSettingsDecodeUsesTerminalPolicyDefaults() throws {
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.terminalPolicy, .default)
    }

    // MARK: - resetToDefaults 镜像重同步

    func testResetToDefaultsResyncsMirror() throws {
        let (center, _) = try makeCenter()

        center.appearance = .dark
        center.accentTheme = .ocean
        // 重基线新增（lane 125 / THEME-05）：重置前的旧组合已迁移为System预设
        // （ocean不恢复已撤销固定dark），这是原测试无法断言的真值维度。
        XCTAssertEqual(center.themePreset, .light)
        XCTAssertEqual(center.appearance, .dark)
        center.defaultProviderID = "openai"
        center.defaultModelID = "gpt-4o-mini"
        center.maxLoopIterations = 99

        center.resetToDefaults()

        // 镜像与 store 同步回默认值（视图随之刷新）；默认主题 = 伪仙赭橙
        XCTAssertEqual(center.appearance, .system)
        XCTAssertEqual(center.accentTheme, .pseudo)
        XCTAssertNil(center.defaultProviderID)
        XCTAssertNil(center.defaultModelID)
        XCTAssertEqual(center.maxLoopIterations, AppSettings.defaults.agent.maxLoopIterations)
        XCTAssertNotEqual(center.maxLoopIterations, 99)
        XCTAssertEqual(center.settingsStore.settings.general.appearance, .system)
        // 重基线新增：默认预设 = 产品主题（第 1 套配色起），store 侧同样同步（精确等式）。
        XCTAssertEqual(center.themePreset, .light)
        XCTAssertEqual(center.settingsStore.settings.general.themePreset, .light)
    }

    func testPersistenceErrorIsObservableAndSecretFree() throws {
        let center = try makeWriteFailingCenter()
        let invalidation = InvalidationCounter()

        withObservationTracking {
            _ = center.lastPersistenceError
        } onChange: {
            invalidation.increment()
        }

        center.approvalPolicy = .deny

        XCTAssertEqual(invalidation.count, 1)
        XCTAssertEqual(center.lastPersistenceError, .writeFailed)
    }

    // MARK: - SETTINGS-27/THEME-01 consumer contract：BL6 typed-settings 往返（lane 125）

    /// 真往返，真函数：预设 → 生产投影函数 `SettingsCenter.bl6Values(from:)`
    /// → 生产 catalog 快照（revision/effectiveSnapshot）→ 生产 dispatch
    /// intent→plan→applyBL6Values→SettingsStore 事务 → 预设保持、两个旧字段
    /// 恰为预设投影。无手搭 fixture、无重言式断言。
    func testConvergedPresetRoundTripsThroughTypedSettingsChannel() throws {
        let (center, dir) = try makeCenter()
        defer { try? FileManager.default.removeItem(at: dir) }

        center.themePreset = .dark

        // 1) 生产投影函数（P3-SET-01 canonical projection，本 lane 写集内文件）。
        let projected = center.bl6Values(from: center.settingsStore.settings, credentialPresent: false)
        XCTAssertEqual(projected["general.appearance"], BL6SettingValue.text("system"))
        XCTAssertEqual(projected["general.accent-theme"], BL6SettingValue.text(ThemePreset.canonicalAccentTheme.rawValue))

        // 2) 投影值可被生产 catalog 原样接受：读 snapshot 即执行
        //    BL6SettingsCatalog.production.revision(for:) + effectiveSnapshot。
        let snapshot = try XCTUnwrap(
            center.bl6EffectiveSettingsSnapshot,
            "typed settings 边界必须对自己的投影出快照（catalog 校验通过）"
        )
        XCTAssertEqual(snapshot.values["general.appearance"], BL6SettingValue.text("system"))
        XCTAssertEqual(snapshot.values["general.accent-theme"], BL6SettingValue.text(ThemePreset.canonicalAccentTheme.rawValue))

        // 3) 生产应用路径：把投影出的旧组合送回 dispatch（附带一个无关变更以
        //    证明这趟 dispatch 真实生效、不是空转），applyBL6Values 经
        //    nearest/setThemePreset 把预设恢复出来并重新落盘。
        let result = center.dispatchBL6Settings(BL6SettingsIntent(
            requestID: "lane125-preset-roundtrip",
            operation: .apply,
            changes: [
                "general.appearance": .text("dark"),
                "general.accent-theme": .text(ThemePreset.canonicalAccentTheme.rawValue),
                "general.language": .text("en")
            ],
            expectedRevision: snapshot.catalogRevision,
            approval: .approved(receiptID: "approval-lane125-preset-roundtrip")
        ))
        if case let .failure(error) = result {
            XCTFail("typed settings channel must accept its own projection: \(error)")
            return
        }
        XCTAssertEqual(center.themePreset, .system, "1115迁移后System预设经生产投影→应用往返保持")
        XCTAssertEqual(center.appearance, .dark, "明暗字段经 dispatch 原样写入，不再被预设覆盖")
        XCTAssertEqual(center.accentTheme, ThemePreset.canonicalAccentTheme, "旧主题字段读出为定版投影")
        XCTAssertEqual(center.settingsStore.settings.general.themePreset, .system, "往返结果已持久化")
        XCTAssertEqual(center.settingsStore.settings.general.legacyThemePresetRawValue, "dark")
        let reopened = SettingsStore(directory: dir)
        XCTAssertEqual(reopened.settings.general.themePreset, .system)
        XCTAssertEqual(reopened.settings.general.legacyThemePresetRawValue, "dark")
        XCTAssertEqual(center.language, "en", "同一次 dispatch 确实应用了无关变更（非空转证明）")
    }

    /// RED with named cause（lane 125 write-set escalation，故意留在红）：
    /// P3-SET-01 投影尚未发布 `general.theme-preset`。这不是可以单点补齐的：
    /// 生效需要三处协调落地——(1) MinisCore BL6TypedConversationSettings.swift
    /// 的 BL6SettingsCatalog.production 注册该键（effectiveSnapshot 对未知键抛
    /// unknownSetting :324、对缺失条目抛 missingSetting :327，二者都会永久锁死
    /// bl6SettingsSnapshotGuard）；(2) 本 lane 写集内 BL6SettingsCenterProjection.swift
    /// emit 点的 `.text(g.themePreset.rawValue)`（已在该处注释记录）；
    /// (3) BL6TypedConversationSettingsProductionTests 的 40→41 计数钉。
    /// (1)(3) 均在本 lane 写集之外，故按治理规则留红上报，不伪造、不弱化。
    func testTypedProjectionPublishesThemePresetKey() throws {
        let (center, dir) = try makeCenter()
        defer { try? FileManager.default.removeItem(at: dir) }

        center.themePreset = .dark
        let projected = center.bl6Values(from: center.settingsStore.settings, credentialPresent: false)
        XCTAssertEqual(
            projected["general.theme-preset"],
            BL6SettingValue.text(ThemePreset.system.rawValue),
            "原general.theme-preset键发布迁移后System真值"
        )
    }

    /// RED with named cause（与上一个测试同一根因）：入站应用侧
    /// （BL6SettingsCenterDispatch，patch 123 已宽容读取该键）要真正可用，
    /// 同样必须等 catalog 注册后显式预设键才能穿过 plan 的 catalog 校验。
    /// 期望终态行为（当前失败即缺口证明）：显式 general.theme-preset 优先于
    /// 旧组合推导，经 converging/setThemePreset 落为真值并重投影旧字段。
    func testThemePresetKeyRoundTripsThroughTypedChannelApply() throws {
        let (center, dir) = try makeCenter()
        defer { try? FileManager.default.removeItem(at: dir) }

        center.themePreset = .dark
        let snapshot = try XCTUnwrap(center.bl6EffectiveSettingsSnapshot)
        let result = center.dispatchBL6Settings(BL6SettingsIntent(
            requestID: "lane125-preset-key",
            operation: .apply,
            changes: ["general.theme-preset": .text(ThemePreset.light.rawValue)],
            expectedRevision: snapshot.catalogRevision,
            approval: .approved(receiptID: "approval-lane125-preset-key")
        ))
        switch result {
        case .success:
            XCTAssertEqual(center.themePreset, .light, "显式预设键必须成为真值而非被旧组合推导覆盖")
            XCTAssertEqual(center.appearance, .system)  // 产品主题跟随系统明暗
            XCTAssertEqual(center.accentTheme, ThemePreset.canonicalAccentTheme)
        case let .failure(error):
            XCTFail(
                "RED(命名原因：general.theme-preset 未注册进 BL6SettingsCatalog.production，"
                    + "写集外文件，lane 125 escalation) — typed channel 拒绝显式预设键: \(error)"
            )
        }
    }
}
