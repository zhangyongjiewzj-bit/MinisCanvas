import Foundation
import Testing
@testable import MinisCore

/// P3-UI-02（明细 :361）：版本化主题预设目录、12% 强调色占比可计算校验、
/// 旧值→新值迁移（幂等 + 总量 + 失败关闭）。
///
/// 覆盖身份（每条计数必须相等，缺一即本文件失效）：
/// - 旧组合枚举数 `legacyPairCount` = 3 Appearance × 6 AccentTheme = 18
/// - 迁移断言数 `migrationAssertionCount` 必须等于 `legacyPairCount`
/// - 目录条目数必须等于 `ThemePresetCatalogID.allCases.count`（2）
///
/// 全部测试为静态可执行定义；本线不跑 swift test（普通 DEV 线验证边界），
/// 因此执行状态由回执记 zero_execution，此处任何断言都不构成 PASS 主张。
struct ThemePresetCatalogTests {

    // MARK: - 覆盖身份常量

    private static let legacyPairCount = Appearance.allCases.count * AccentTheme.allCases.count
    private static let expectedLegacyPairCount = 18

    private static var allLegacyPairs: [(Appearance, AccentTheme)] {
        Appearance.allCases.flatMap { a in AccentTheme.allCases.map { t in (a, t) } }
    }

    private static func legacyCombination(_ appearance: Appearance, _ accent: AccentTheme) -> String {
        "\(appearance.rawValue)\(ThemePresetCatalogMigration.legacyCombinationSeparator)\(accent.rawValue)"
    }

    // MARK: - 目录版本化与两预设收录

    @Test func catalogIsVersionedAndCarriesBothNamedPresets() {
        #expect(ThemePresetCatalog.version == 1)
        #expect(ThemePresetCatalog.entries.count == ThemePresetCatalogID.allCases.count)
        #expect(ThemePresetCatalog.entries.count == 2)
        // 确定性顺序：keylineOrangeA7A 在前（唯一已批准预设）。
        #expect(ThemePresetCatalog.entries.map(\.id) == [.keylineOrangeA7A, .warmCoralA7A])
        for entry in ThemePresetCatalog.entries {
            #expect(entry.catalogVersion == ThemePresetCatalog.version)
        }
    }

    /// keylineOrangeA7A 亮侧色值必须与已批准字面量逐字节同源，目录不得改色。
    @Test func keylineOrangeAccentMatchesApprovedLiteralWithoutMutation() {
        let entry = ThemePresetCatalog.entry(for: .keylineOrangeA7A)
        #expect(entry != nil)
        let accent = entry?.accent(for: .light)
        #expect(accent != nil)
        // 第 1 套配色：亮侧强调 #A84E2A（0xA8/0x4E/0x2A ÷ 255），取代原 #D97707。
        #expect(accent?.r == Double(0xA8) / 255.0)
        #expect(accent?.g == Double(0x4E) / 255.0)
        #expect(accent?.b == Double(0x2A) / 255.0)
        #expect(entry?.acceptance == .acceptedForLight)
    }

    /// 用户 11/17 选定第 1 套（含深色）：暗侧强调色 #E08B68 获批，暗侧裁决放开。
    @Test func darkBranchCarriesApprovedDarkAccent() {
        #expect(ThemePresetCatalog.darkBranchAdjudication == .approved)
        let entry = ThemePresetCatalog.entry(for: .keylineOrangeA7A)
        #expect(entry?.darkAccent?.r == Double(0xE0) / 255.0)
        #expect(entry?.darkAccent?.g == Double(0x8B) / 255.0)
        #expect(entry?.accent(for: .dark)?.b == Double(0x68) / 255.0)
    }

    /// warmCoralA7A 被点名但本头零批准色板材料 → 注册不猜色。
    @Test func warmCoralIsRegisteredButCarriesNoInventedColor() {
        let entry = ThemePresetCatalog.entry(for: .warmCoralA7A)
        #expect(entry != nil)
        #expect(entry?.acceptance == .pendingColorMaterial)
        #expect(entry?.accent(for: .light) == nil)
        #expect(entry?.accent(for: .dark) == nil)
        // 未验收预设不出现在可选集合，但也不被静默删除。
        #expect(ThemePresetCatalog.selectableIDs == [.keylineOrangeA7A])
        #expect(ThemePresetCatalogID.allCases.contains(.warmCoralA7A))
    }

    // MARK: - 12% 强调色占比可计算校验

    @Test func coverageCeilingIsTwelvePercent() {
        #expect(ThemePresetCatalog.accentCoverageCeilingFraction == 0.12)
    }

    @Test func coverageAssessmentIsComputableAndDeterministic() {
        // 单区域：0.10 全不透明 → 上限内。
        let below = ThemePresetCatalog.assessAccentCoverage([
            ThemeAccentPaintedRegion(areaFraction: 0.10, paintOpacity: 1.0),
        ])
        #expect(below == .withinCeiling(effectiveCoverage: 0.10))
        // 恰好 12%（定版用法 opacity(0.12) 涂满一个 1/12 面区域等价占比）→ 边界内。
        let atCeiling = ThemePresetCatalog.assessAccentCoverage([
            ThemeAccentPaintedRegion(areaFraction: 0.12, paintOpacity: 1.0),
        ])
        #expect(atCeiling.isWithinCeiling)
        // 0.13 → 超限。
        let over = ThemePresetCatalog.assessAccentCoverage([
            ThemeAccentPaintedRegion(areaFraction: 0.13, paintOpacity: 1.0),
        ])
        #expect(over == .exceedsCeiling(effectiveCoverage: 0.13))
        // 多区域累加：0.06 + 0.06 = 0.12 上限内；0.07 + 0.06 超限。
        let splitPass = ThemePresetCatalog.assessAccentCoverage([
            ThemeAccentPaintedRegion(areaFraction: 0.06, paintOpacity: 1.0),
            ThemeAccentPaintedRegion(areaFraction: 0.06, paintOpacity: 1.0),
        ])
        #expect(splitPass.isWithinCeiling)
        let splitFail = ThemePresetCatalog.assessAccentCoverage([
            ThemeAccentPaintedRegion(areaFraction: 0.07, paintOpacity: 1.0),
            ThemeAccentPaintedRegion(areaFraction: 0.06, paintOpacity: 1.0),
        ])
        #expect(!splitFail.isWithinCeiling)
        // 不透明度参与乘积：0.5 面积 × 0.2 不透明 = 0.10 有效占比。
        let faded = ThemePresetCatalog.assessAccentCoverage([
            ThemeAccentPaintedRegion(areaFraction: 0.5, paintOpacity: 0.2),
        ])
        #expect(faded.isWithinCeiling)
        // 空集合 = 0 覆盖。
        #expect(ThemePresetCatalog.assessAccentCoverage([]) == .withinCeiling(effectiveCoverage: 0.0))
        // 确定性：同一输入重复评估结果逐位一致。
        for _ in 0..<25 {
            #expect(ThemePresetCatalog.assessAccentCoverage([
                ThemeAccentPaintedRegion(areaFraction: 0.13, paintOpacity: 1.0),
            ]) == over)
        }
    }

    @Test func coverageRejectsInvalidInputFailClosed() {
        let badArea = ThemePresetCatalog.assessAccentCoverage([
            ThemeAccentPaintedRegion(areaFraction: -0.1, paintOpacity: 1.0),
        ])
        if case .rejectedInvalidInput(let reasons) = badArea {
            #expect(reasons.contains(.areaFractionOutOfRange))
        } else {
            Issue.record("负面积占比必须被拒绝而不是判过: \(badArea)")
        }
        let bigArea = ThemePresetCatalog.assessAccentCoverage([
            ThemeAccentPaintedRegion(areaFraction: 1.5, paintOpacity: 0.1),
        ])
        #expect(bigArea.isWithinCeiling == false)
        let badOpacity = ThemePresetCatalog.assessAccentCoverage([
            ThemeAccentPaintedRegion(areaFraction: 0.05, paintOpacity: 1.2),
        ])
        #expect(badOpacity.isWithinCeiling == false)
        let overlappingAreas = ThemePresetCatalog.assessAccentCoverage([
            ThemeAccentPaintedRegion(areaFraction: 0.7, paintOpacity: 0.1),
            ThemeAccentPaintedRegion(areaFraction: 0.7, paintOpacity: 0.1),
        ])
        if case .rejectedInvalidInput(let reasons) = overlappingAreas {
            #expect(reasons.contains(.totalAreaExceedsSurface))
        } else {
            Issue.record("区域总面积超过表面必须被拒绝: \(overlappingAreas)")
        }
        let nonFinite = ThemePresetCatalog.assessAccentCoverage([
            ThemeAccentPaintedRegion(areaFraction: Double.nan, paintOpacity: 1.0),
        ])
        if case .rejectedInvalidInput(let reasons) = nonFinite {
            #expect(reasons.contains(.areaFractionNotFinite))
        } else {
            Issue.record("非有限输入必须被拒绝: \(nonFinite)")
        }
        // 拒绝原因按 rawValue 排序，输出确定。
        #expect(
            [ThemeAccentCoverageInvalidReason.totalAreaExceedsSurface,
             ThemeAccentCoverageInvalidReason.areaFractionOutOfRange].sorted()
            == [.areaFractionOutOfRange, .totalAreaExceedsSurface]
        )
    }

    // MARK: - 迁移：18 组合全覆盖

    /// 全部 18 种旧「外观|主题色」组合都被识别并迁移到唯一已批准预设；
    /// 断言组数 == 组合枚举数（覆盖身份）。
    @Test func migrationCoversEveryLegacyCombination() {
        #expect(ThemePresetCatalogMigration.legacyCombinationCount == Self.expectedLegacyPairCount)
        #expect(ThemePresetCatalogMigration.legacyCombinationCount == Self.legacyPairCount)
        var assertionCount = 0
        for (appearance, accent) in Self.allLegacyPairs {
            let result = ThemePresetCatalogMigration.migrate(
                storedValue: Self.legacyCombination(appearance, accent)
            )
            #expect(result.status == .migrated)
            #expect(result.presetID == .keylineOrangeA7A)
            #expect(result.canonicalStoredValue == "preset.keylineOrangeA7A")
            switch appearance {
            case .light: #expect(result.branch == .fixedLight)
            case .dark: #expect(result.branch == .fixedDark)
            case .system: #expect(result.branch == .systemMirror)
            }
            assertionCount += 1
        }
        #expect(assertionCount == Self.legacyPairCount)
        #expect(assertionCount == Self.expectedLegacyPairCount)
    }

    /// 明暗信息不丢失（两分支中性能力）；主题色轴已收敛不再区分。
    @Test func migrationKeepsAppearanceBranchNeutral() {
        let darkMapped = Set(AccentTheme.allCases.map {
            ThemePresetCatalogMigration.migrate(storedValue: Self.legacyCombination(.dark, $0)).branch
        })
        #expect(darkMapped == [.fixedDark])
        let systemMapped = Set(AccentTheme.allCases.map {
            ThemePresetCatalogMigration.migrate(storedValue: Self.legacyCombination(.system, $0)).branch
        })
        #expect(systemMapped == [.systemMirror])
        // System 豁免裁决 pending：目录只镜像，不裁决。
        #expect(ThemePresetCatalog.systemBranchAdjudication == .pending)
    }

    /// 旧 ThemePreset 存储值同样被识别（高对比保留 fixedHighContrast 身份）。
    @Test func migrationMapsLegacyPresetRawValues() {
        #expect(ThemePresetCatalogMigration.migrate(storedValue: "light").branch == .fixedLight)
        #expect(ThemePresetCatalogMigration.migrate(storedValue: "dark").branch == .fixedDark)
        #expect(ThemePresetCatalogMigration.migrate(storedValue: "system").branch == .systemMirror)
        let highContrast = ThemePresetCatalogMigration.migrate(storedValue: "highContrast")
        #expect(highContrast.status == .migrated)
        #expect(highContrast.branch == .fixedHighContrast)
        #expect(highContrast.presetID == .keylineOrangeA7A)
    }

    // MARK: - 迁移：幂等

    /// 对任一识别输入的迁移结果再迁移其规范存储值：alreadyCurrent，
    /// 预设与规范值逐字段不变；三次重放仍相同。
    @Test func migrationIsIdempotentAcrossAllRecognizedInputs() {
        var inputs = Self.allLegacyPairs.map { Self.legacyCombination($0, $1) }
        inputs += ["light", "dark", "system", "highContrast"]
        inputs += ThemePresetCatalogID.allCases.map(\.rawValue)
        inputs += ThemePresetCatalogID.allCases.map {
            ThemePresetCatalogMigration.canonicalStoredValue(for: $0)
        }
        for input in inputs {
            let once = ThemePresetCatalogMigration.migrate(storedValue: input)
            guard let canonical = once.canonicalStoredValue else {
                Issue.record("识别输入不应被拒绝: \(input)")
                continue
            }
            let twice = ThemePresetCatalogMigration.migrate(storedValue: canonical)
            #expect(twice.status == .alreadyCurrent)
            #expect(twice.presetID == once.presetID)
            #expect(twice.canonicalStoredValue == canonical)
            let thrice = ThemePresetCatalogMigration.migrate(
                storedValue: twice.canonicalStoredValue ?? "<impossible>"
            )
            #expect(thrice == twice)
        }
    }

    // MARK: - 迁移：总量 + 失败关闭

    /// 总函数：任意字符串都有结论；未知输入一律 rejected，
    /// 不携带预设、不携带规范值——不存在静默默认路径。
    @Test func migrationIsTotalAndFailsClosedOnUnknownInput() {
        let unknowns: [String] = [
            "",
            " ",
            "not-a-theme",
            "|",
            "light|",
            "|pseudo",
            "light|bogus",
            "bogus|pseudo",
            "light|pseudo|system",
            "preset.",
            "preset.unknownPresetID",
            "KEYLINEORANGEA7A",
            "keylineorangea7A",
            " keylineOrangeA7A",
            "Light",
            "preset.keylineOrangeA7A ",
        ]
        for raw in unknowns {
            let result = ThemePresetCatalogMigration.migrate(storedValue: raw)
            #expect(result.status == .rejected, "未知输入不得被接受: \(raw)")
            #expect(result.presetID == nil, "未知输入不得静默携带预设: \(raw)")
            #expect(result.canonicalStoredValue == nil, "未知输入不得静默产出规范值: \(raw)")
            #expect(result.rejection != nil)
        }
        // 空值与畸形组合的原因码可区分（供记账与恢复路径引用）。
        #expect(ThemePresetCatalogMigration.migrate(storedValue: "").rejection == .emptyStoredValue)
        #expect(ThemePresetCatalogMigration.migrate(storedValue: "a|b|c").rejection == .malformedLegacyCombination)
        #expect(ThemePresetCatalogMigration.migrate(storedValue: "bogus|pseudo").rejection == .unknownAppearanceRawValue)
        #expect(ThemePresetCatalogMigration.migrate(storedValue: "light|bogus").rejection == .unknownAccentRawValue)
        #expect(ThemePresetCatalogMigration.migrate(storedValue: "not-a-theme").rejection == .unknownStoredValue)
        // 全函数性抽样：对任意输入恒返回四种状态之一（迁移表穷尽）。
        for raw in unknowns + ["light|pseudo", "preset.warmCoralA7A"] {
            let status = ThemePresetCatalogMigration.migrate(storedValue: raw).status
            #expect([ThemePresetCatalogMigrationResult.Status.migrated,
                     .alreadyCurrent, .rejected].contains(status))
        }
    }

    /// 已注册但未验收的预设 id 是合法当前值（alreadyCurrent），
    /// 但选择权仍由目录验收状态把守，迁移不越权放行。
    @Test func registeredButUnacceptedIDRoundTripsWithoutSelectionPromotion() {
        let result = ThemePresetCatalogMigration.migrate(storedValue: "preset.warmCoralA7A")
        #expect(result.status == .alreadyCurrent)
        #expect(result.presetID == .warmCoralA7A)
        #expect(ThemePresetCatalog.selectableIDs.contains(.warmCoralA7A) == false)
    }
}
