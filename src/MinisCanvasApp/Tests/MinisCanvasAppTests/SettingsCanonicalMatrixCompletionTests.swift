import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// P3-SET-01 · lane 136：矩阵完整性绑定。
///
/// `minisCanvas.sidebarWidth`（lane 081 合同）、`general.themePreset`
/// （lane 123 收敛后的唯一外观真值）与 `storage.memoryLimitMB`
/// （lane 076 consumer 驱动的设置）在合入候选时缺少
/// `PersistentStateDescriptor` 矩阵条目。本套件断言这三项绑定经
/// 生产消费者真实生效——`SettingsStateClassification.canonicalDescriptor(for:)`
/// 查找与 `SettingsCenter.settingsAppliedStateProjection`（设置页
/// 「应用状态」横幅的真实数据源）——不钉任何条目计数。
@Suite("P3-SET-01 canonical matrix completion")
struct SettingsCanonicalMatrixCompletionTests {

    /// 合同条目逐字并入：矩阵中的条目与 `SessionSidebarWidthContract.descriptor`
    /// 值相等（081 集成配方第 1 步；不重述字段文本，避免第二份真相）。
    @Test
    func sidebarWidthDescriptorIsMergedVerbatimFromContract() {
        #expect(
            SettingsStateClassification.canonicalDescriptor(
                for: SessionSidebarWidthContract.settingsKey
            ) == SessionSidebarWidthContract.descriptor
        )
    }

    /// 两条新增条目各自绑定唯一 settingsKey、真实 owner 有效源与
    /// settings.json 持久化域（与既有 canonical 条目同域）。
    @Test
    func mergedCanonicalSettingsCarryKeyEffectiveSourceAndPersistence() throws {
        for key in ["general.themePreset", "storage.memoryLimitMB"] {
            let descriptor = try #require(
                SettingsStateClassification.canonicalDescriptor(for: key),
                "P3-SET-01 矩阵缺少 \(key) 绑定"
            )
            #expect(descriptor.stateClass == .canonicalSetting)
            #expect(descriptor.settingsKey == key)
            #expect(descriptor.owner == "SettingsCenter")
            #expect(descriptor.effectiveSource?.isEmpty == false)
            #expect(descriptor.persistence == "SettingsStore.settings.json")
            // 全部三条 restart 声明为即时生效（含按新准入生效），
            // 不得被误分类为 restart_required。
            #expect(
                SettingsStateClassification.applyState(for: descriptor) == .liveApplied
            )
        }
    }

    /// 矩阵条目驱动真实生产投影：设置页应用状态横幅按 key 列出
    /// liveAppliedSettingKeys。此处只断言新 key 的归属，不断言计数。
    @Test @MainActor
    func newMatrixEntriesSurfaceInProductionAppliedStateProjection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3SET01Matrix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10)
        )
        let projection = center.settingsAppliedStateProjection
        for key in [
            SessionSidebarWidthContract.settingsKey,
            "general.themePreset",
            "storage.memoryLimitMB"
        ] {
            #expect(projection.liveAppliedSettingKeys.contains(key))
            #expect(!projection.restartRequiredSettingKeys.contains(key))
        }
    }

    /// 有效源真实性：`SettingsCenter.themePreset` 是矩阵声明的那个值，
    /// 旧投影字段随预设联动（单一真值，不可各自漂移）。
    @Test @MainActor
    func themePresetEffectiveSourceIsTheRealCenterProperty() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3SET01Preset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10)
        )
        #expect(
            SettingsStateClassification.canonicalDescriptor(for: "general.themePreset")?
                .effectiveSource == "SettingsCenter.themePreset"
        )
        center.themePreset = .light
        #expect(center.themePreset == .light)
        #expect(center.appearance == .system)   // 产品主题跟随系统明暗
        #expect(center.accentTheme == ThemePreset.canonicalAccentTheme)
        #expect(SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10)
        ).themePreset == .light)
        // A legacy request cannot persist a retired preset or its old
        // appearance projection as a separate effective source.
        center.themePreset = .dark
        #expect(center.themePreset == .system)
        #expect(center.appearance == .system)
    }

    /// 有效源真实性：矩阵 key 与设置中心属性、持久化镜像同源；
    /// 清空回落 nil（默认「不限制」）在同一路径上成立。
    @Test @MainActor
    func memoryLimitEffectiveSourceRoundTripsThroughCenter() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3SET01MemLimit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10)
        )
        #expect(
            SettingsStateClassification.canonicalDescriptor(for: "storage.memoryLimitMB")?
                .effectiveSource == "SettingsCenter.memoryLimitMB"
        )
        #expect(center.memoryLimitMB == nil)
        center.memoryLimitMB = 8
        #expect(center.memoryLimitMB == 8)
        #expect(center.settingsMirror.storage.memoryLimitMB == 8)
        center.memoryLimitMB = nil
        #expect(center.memoryLimitMB == nil)
        #expect(center.settingsMirror.storage.memoryLimitMB == nil)
    }

    /// A durable PolicyRuntime ceiling save reattaches production for the next
    /// turn. The Settings applied-state consumer must not advertise a restart.
    @Test @MainActor
    func policyRuntimeCeilingSaveSurfacesAsLiveApplied() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3SET01PolicyCeiling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10)
        )
        let key = "agent.policyRuntimeDefaults"
        let descriptor = try #require(SettingsStateClassification.canonicalDescriptor(for: key))
        #expect(descriptor.effectiveSource == "SettingsCenter.policyRuntimeDefaults")
        let before = center.settingsAppliedStateProjection.settingsRevision
        var ceiling = center.policyRuntimeDefaults
        ceiling.budget = 7
        #expect(center.updatePolicyRuntimeDefaults(ceiling))
        #expect(SettingsStore(directory: directory).settings.agent.policyRuntimeDefaults == ceiling)

        let applied = center.settingsAppliedStateProjection
        #expect(applied.settingsRevision != before)
        #expect(SettingsStateClassification.applyState(for: descriptor) == .liveApplied)
        #expect(applied.liveAppliedSettingKeys.contains(key))
        #expect(!applied.restartRequiredSettingKeys.contains(key))
    }
}
