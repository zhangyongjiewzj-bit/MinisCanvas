import XCTest
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - P3-UI-02（N-UI02-WIRE）主题预设目录生产消费接线焦点测试（lane DEV-290）
//
// 本头接线前实测缺口（复现于 base head 70951dd80，grep rc=1）：
// `src/MinisCanvasApp` 生产侧对 MinisCore `ThemePresetCatalog` /
// `ThemePresetCatalogMigration` 零引用。本文件钉住接线后的消费语义：
// 1) 投影腿发布值与 lanes 125/140 既有测试钉逐值一致（不改产品语义）；
// 2) 收敛腿经目录迁移全函数，失败关闭语义与原 converging/nearest 双腿
//    逐输入一致，新增识别仅限 canonical :361「旧值迁移」点名的旧组合串；
// 3) 选择器候选集由目录亮侧已批准集合门控（.pending 下不发明豁免、
//    不为 warmCoralA7A 造色）。
// 断言只比对既有目录定义与已验收符号，不写任何新色值字面量。

@MainActor
final class ThemePresetCatalogConsumerWiring290Tests: XCTestCase {

    private func makeCenter() throws -> (SettingsCenter, URL) {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "theme1524", canvasRuntimeState: .disabled)
        let root = profile.rootDirectory
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let suite = "theme1524-" + root.lastPathComponent
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
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

    // MARK: 1) 投影腿：general.theme-preset 发布值语义不变（既有钉逐值保持）

    func testPublishedPresetValueKeepsAcceptedPresetPinsByteIdentical() {
        // lanes 125/140 的精确断言语义：已验收外观预设发布的仍是其 rawValue。
        XCTAssertEqual(
            BL6ThemePresetCatalogConsumer.publishedThemePresetValue(for: .light),
            ThemePreset.light.rawValue
        )
        XCTAssertEqual(
            BL6ThemePresetCatalogConsumer.publishedThemePresetValue(for: .dark),
            ThemePreset.system.rawValue
        )
        XCTAssertEqual(
            BL6ThemePresetCatalogConsumer.publishedThemePresetValue(for: .system),
            ThemePreset.system.rawValue
        )
    }

    func testPublishedHighContrastKeepsExplicitPresetIdentity949() {
        // Explicit high contrast retains its raw identity through catalog projection.
        XCTAssertEqual(
            BL6ThemePresetCatalogConsumer.publishedThemePresetValue(for: .highContrast),
            ThemePreset.system.rawValue
        )
    }

    func testLiveProjectionPublishesPresetKeyThroughCatalog() throws {
        let (center, dir) = try makeCenter()
        defer { try? FileManager.default.removeItem(at: dir) }

        center.themePreset = .dark
        let projected = center.bl6Values(from: center.settingsStore.settings, credentialPresent: false)
        // 真实投影路径（非静态 fixture）：经 SettingsCenter.bl6Values →
        // BL6ThemePresetCatalogConsumer → ThemePresetCatalogMigration。
        XCTAssertEqual(
            projected["general.theme-preset"],
            .text(ThemePreset.system.rawValue),
            "投影腿接目录后，已验收预设发布值与接线前逐值一致"
        )
        XCTAssertEqual(
            projected["general.theme-preset"],
            .text(BL6ThemePresetCatalogConsumer.publishedThemePresetValue(for: center.settingsMirror.general.themePreset))
        )
    }

    // MARK: 2) 收敛腿：dispatch 派发段经目录迁移全函数

    func testConvergenceLegRestoresLegacyAppearanceValuesViaCatalogBranch() {
        // 旧 ThemePreset 存储值：迁移分支逐项映回同一预设（与 converging 一致）。
        XCTAssertEqual(
            BL6ThemePresetCatalogConsumer.convergedAppearancePreset(
                storedRawValue: "light", legacyAppearance: .dark, legacyAccentTheme: .pseudo
            ),
            .light
        )
        XCTAssertEqual(
            BL6ThemePresetCatalogConsumer.convergedAppearancePreset(
                storedRawValue: "dark", legacyAppearance: .light, legacyAccentTheme: .pseudo
            ),
            .system
        )
        XCTAssertEqual(
            BL6ThemePresetCatalogConsumer.convergedAppearancePreset(
                storedRawValue: "system", legacyAppearance: .light, legacyAccentTheme: .pseudo
            ),
            .system
        )
    }

    func testConvergenceLegMissingEmptyOrRejectedFallsBackToNearest() {
        // 键缺失 / 空值 / rejected（未知串、malformed 组合）→ 旧组合确定性映射，
        // 与接线前 converging 的回退腿逐输入一致；绝不静默给默认色。
        for raw: String? in [nil, "", "not-a-preset", "dark|", "|crimson", "dark|no-such-accent|extra"] {
            XCTAssertEqual(
                BL6ThemePresetCatalogConsumer.convergedAppearancePreset(
                    storedRawValue: raw, legacyAppearance: .dark, legacyAccentTheme: .crimson
                ),
                ThemePreset.nearest(for: .dark, accentTheme: .crimson),
                "raw=\(raw ?? "<missing>") 应失败闭到 nearest 回退"
            )
        }
    }

    func testConvergenceLegRestoresExplicitHighContrast949() {
        // The same catalog consumer preserves the newly complete fourth preset.
        XCTAssertEqual(
            BL6ThemePresetCatalogConsumer.convergedAppearancePreset(
                storedRawValue: ThemePreset.highContrast.rawValue,
                legacyAppearance: .system,
                legacyAccentTheme: .pseudo
            ),
            .system
        )
    }

    func testUnknownAndPendingMaterialStillFailClosed949() {
        for raw in ["unknown-preset", "highContrast|unknown", "preset.warmCoralA7A"] {
            XCTAssertEqual(BL6ThemePresetCatalogConsumer.convergedAppearancePreset(
                storedRawValue: raw, legacyAppearance: .light, legacyAccentTheme: .pseudo), .light)
        }
        XCTAssertNil(ThemePresetCatalog.entry(for: .warmCoralA7A)?.lightAccent)
        XCTAssertNil(ThemePresetCatalog.entry(for: .warmCoralA7A)?.darkAccent)
    }

    func testConvergenceLegAcceptsCatalogCanonicalWordWithoutInventingBranch() {
        // 目录规范词（alreadyCurrent）不携带明暗轴信息 → 不猜测分支，
        // 由旧组合键确定性映射（保持原 converging 对该形态的回退语义）。
        let canonical = ThemePresetCatalogMigration.canonicalStoredValue(for: .keylineOrangeA7A)
        XCTAssertEqual(
            BL6ThemePresetCatalogConsumer.convergedAppearancePreset(
                storedRawValue: canonical, legacyAppearance: .light, legacyAccentTheme: .pseudo
            ),
            .light
        )
        XCTAssertEqual(
            BL6ThemePresetCatalogConsumer.convergedAppearancePreset(
                storedRawValue: canonical, legacyAppearance: .dark, legacyAccentTheme: .pseudo
            ),
            .system
        )
    }

    func testConvergenceLegMigratesLegacy18CombinationStringsPerCanonical361() {
        // canonical :361「旧值迁移」腿："<appearance>|<accent>" 旧 18 组合串
        // 被目录迁移识别并携带中性明暗分支 → 显式预设键优先于旧组合推导。
        // 暗侧只还原外观轴预设，不推导任何暗侧色值（豁免裁决保持 .pending）。
        XCTAssertEqual(
            BL6ThemePresetCatalogConsumer.convergedAppearancePreset(
                storedRawValue: "dark|crimson", legacyAppearance: .light, legacyAccentTheme: .pseudo
            ),
            .system
        )
        XCTAssertEqual(
            BL6ThemePresetCatalogConsumer.convergedAppearancePreset(
                storedRawValue: "light|ocean", legacyAppearance: .system, legacyAccentTheme: .pseudo
            ),
            .light
        )
        XCTAssertEqual(
            BL6ThemePresetCatalogConsumer.convergedAppearancePreset(
                storedRawValue: "system|pseudo", legacyAppearance: .dark, legacyAccentTheme: .crimson
            ),
            .system
        )
    }

    // MARK: 3) 选择器目录闸：候选集由亮侧已批准集合门控

    func testPickerGateMatchesCatalogApprovedLightSetAtHead() {
        // 接线排重依据：目录 v1 亮侧已批准且具色的集合恰为 {keylineOrangeA7A}；
        // warmCoralA7A 无材料（lightAccent == nil）→ 不具色、不入门。
        XCTAssertEqual(ThemePresetCatalog.selectableIDs, [ThemePresetCatalogID.keylineOrangeA7A])
        XCTAssertNotNil(
            ThemePresetCatalog.entry(for: .keylineOrangeA7A)?.accent(for: .light),
            "keylineOrangeA7A 亮侧为已批准材料"
        )
        XCTAssertNil(ThemePresetCatalog.entry(for: .warmCoralA7A)?.lightAccent)
        XCTAssertNil(ThemePresetCatalog.entry(for: .warmCoralA7A)?.accent(for: .dark))
        // 本头闸放行后选择器可见集合与接线前 ThemePreset.selectable 逐值一致；
        // Fourth preset is backed by its own complete semantic layer.
        XCTAssertEqual(
            ThemePresetCatalogPickerGate.selectableThemePresets,
            ThemePreset.selectable
        )
        XCTAssertFalse(ThemePresetCatalogPickerGate.selectableThemePresets.contains(.highContrast))
        XCTAssertEqual(ThemePresetCatalogPickerGate.selectableThemePresets, [.light, .system])
    }

    func testDarkAndSystemBranchAdjudicationStaysPending() {
        // 不发明豁免：接线后目录的 dark/System 分支裁决记录仍是唯一合法值。
        XCTAssertEqual(ThemePresetCatalog.darkBranchAdjudication, .pending)
        XCTAssertEqual(ThemePresetCatalog.systemBranchAdjudication, .pending)
        XCTAssertNil(
            ThemePresetCatalog.entry(for: .keylineOrangeA7A)?.accent(for: .dark),
            "暗侧色值在裁决前保持失败关闭（nil），本线未填充"
        )
    }
}
