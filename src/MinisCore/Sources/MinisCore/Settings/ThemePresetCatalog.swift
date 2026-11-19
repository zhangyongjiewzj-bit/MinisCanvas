import Foundation

// MARK: - P3-UI-02 版本化主题预设目录（keylineOrangeA7A / warmCoralA7A）
//
// 本文件是需求 P3-UI-02（明细 :361 —— 18 组合与 System 明暗仍开放；
// keylineOrangeA7A 已批准为预设）的 MinisCore producer 层：一个无 UI 依赖、
// 版本化、可被测试逐值断言的预设目录。App 侧消费方（SettingsCenter /
// SettingsView）在本头处于 held 写集，本线不接线（consumer_at_head:
// none_deferred），因此这里只定版语义与迁移，不改变任何渲染行为。
//
// 硬约束（派工单 §2 第 4/5 条 + AGENTS.md A7-A 视觉约束）：
// - 不改动已批准色值字面量，只为其版本化与暴露：keylineOrangeA7A 的亮侧
//   强调色与仓库既有定版符号 MinisIconTokens.keylineOrangeA7A
//   （sRGB 分量 0xD9/0x77/0x07，见 MinisIconTokens.swift:18）逐字节同源，
//   本目录不引入任何新色值。
// - dark/System 是否豁免属待裁决事项（adjudication_pending）：本文件只
//   中性地实现「明暗两分支都可表示」的能力，不自造任何豁免规则；在裁决
//   与批准色板材料落地之前，暗分支不提供色值、warmCoralA7A 不猜测色值
//   （该词在本头全仓实测零命中）。未验收即失败关闭（fail closed），
//   这些目录强调色的待裁定状态不由外观高对比预设代为批准。

// MARK: - 预设身份

/// 版本化目录中的预设标识；rawValue 是目录的稳定存储词。
public enum ThemePresetCatalogID: String, Codable, CaseIterable, Sendable {
    /// A7-A 定版强调橙（唯一执行单 :230 已批准为亮色主题预设）。
    case keylineOrangeA7A
    /// 需求点名的第二预设；本头无任何已批准色板材料（全仓实测 0 命中），
    /// 注册但不填充色值，等待设计授权材料，不自造语义。
    case warmCoralA7A
}

/// 目录强调色的材料状态：
/// 被需求点名但无批准材料 → 保留在目录中显式标记未填充，而非静默删除。
public enum ThemePresetCatalogAcceptance: String, Equatable, Sendable {
    /// 已批准且具备定版色值材料（当前仅亮侧）。
    case acceptedForLight
    /// 需求点名但无批准色值材料 → 不猜测色值。
    case pendingColorMaterial
}

/// dark/System 分支相对亮侧约束的豁免裁决状态。当前唯一取值是「待裁决」；
/// 本枚举只承载该事实，供记账与回执引用，不构成任何豁免行为或色值推导。
public enum ThemePresetBranchAdjudication: String, Equatable, Sendable {
    case pending
    /// 用户 11/17 选定第 1 套配色（含深色）：产品主题暗侧强调色获批。
    case approved
}

/// 迁移结果携带的中性明暗分支表示（两分支能力，均不预设豁免结论）。
public enum ThemePresetMigrationBranch: String, Equatable, Sendable {
    /// 旧值为固定浅色。
    case fixedLight
    /// 旧值为固定深色（暗侧色值在裁决前不可解析，见 entry.darkAccent）。
    case fixedDark
    /// 旧值为跟随系统（运行时按 macOS 真实明暗镜像到既有两分支）。
    case systemMirror
    /// 显式高对比：同一 palette 的固定深色增强层级。
    case fixedHighContrast
    /// 旧值不含可识别明暗信息。
    case indeterminate
}

// MARK: - 目录条目

/// 一条版本化预设记录。所有字段都是纯数据，无 SwiftUI 依赖。
public struct ThemePresetCatalogEntry: Equatable, Sendable {
    public let id: ThemePresetCatalogID
    /// 该条目所属的目录版本；与 `ThemePresetCatalog.version` 恒等。
    public let catalogVersion: Int
    public let acceptance: ThemePresetCatalogAcceptance
    /// 亮侧强调色；nil = 无已批准色值材料（不猜测）。
    public let lightAccent: ThemeColor?
    /// 暗侧强调色；dark 豁免待裁决且本头无 A7A 暗侧批准材料 → 恒为 nil，
    /// 字段存在即「两分支可表示」的中性能力，裁决落地后由其承载定版色值。
    public let darkAccent: ThemeColor?

    public init(
        id: ThemePresetCatalogID,
        catalogVersion: Int,
        acceptance: ThemePresetCatalogAcceptance,
        lightAccent: ThemeColor?,
        darkAccent: ThemeColor?
    ) {
        self.id = id
        self.catalogVersion = catalogVersion
        self.acceptance = acceptance
        self.lightAccent = lightAccent
        self.darkAccent = darkAccent
    }

    /// 按明暗解析强调色；未批准侧返回 nil（失败关闭，绝不回落到猜测值）。
    public func accent(for mode: ThemeMode) -> ThemeColor? {
        switch mode {
        case .light: lightAccent
        case .dark: darkAccent
        }
    }
}

// MARK: - 强调色占比（12% 上限）可计算校验

/// 一处被强调色涂抹的区域：面积占比 × 涂抹不透明度。
///
/// 「有效占比」= Σ(areaFraction × paintOpacity)，上限为目录常数
/// `ThemePresetCatalog.accentCoverageCeilingFraction`（12%）。输入非法时
/// 拒绝评估而不是悄悄判过或悄悄截断。
public struct ThemeAccentPaintedRegion: Equatable, Sendable {
    /// 区域面积占有效表面总面积的比例（0...1）。
    public let areaFraction: Double
    /// 该区域强调色涂抹不透明度（0...1）。
    public let paintOpacity: Double

    public init(areaFraction: Double, paintOpacity: Double) {
        self.areaFraction = areaFraction
        self.paintOpacity = paintOpacity
    }
}

/// 占比校验结论。
public enum ThemeAccentCoverageAssessment: Equatable, Sendable {
    case withinCeiling(effectiveCoverage: Double)
    case exceedsCeiling(effectiveCoverage: Double)
    case rejectedInvalidInput(reasons: [ThemeAccentCoverageInvalidReason])

    public var isWithinCeiling: Bool {
        if case .withinCeiling = self { return true }
        return false
    }
}

/// 非法输入原因（确定性可断言，不携带任何用户输入原文）。
public enum ThemeAccentCoverageInvalidReason: String, Equatable, Sendable, Comparable {
    case areaFractionNotFinite
    case areaFractionOutOfRange
    case paintOpacityNotFinite
    case paintOpacityOutOfRange
    case totalAreaExceedsSurface

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - 目录本体

/// 版本化主题预设目录。v1 收录 A7-A 已批准的 keylineOrangeA7A 与需求点名
/// 但尚无批准色板材料的 warmCoralA7A。
public enum ThemePresetCatalog {
    /// 目录版本；新增/变更预设条目时必须提升并由迁移层引用。
    public static let version = 1

    /// 强调色有效占比上限（12%）。语义出处：A7-A 定版强调橙在设置页的
    /// 唯一批准用法 `opacity(0.12)`（SettingsView.swift:494 站点）与派工
    /// 单「强调色占比上限 12%」条款；本目录只把它变成可计算谓词，
    /// 不新增其他占比规则。
    public static let accentCoverageCeilingFraction: Double = 0.12

    /// 浮点比较容差：仅覆盖 IEEE754 求和噪声（10 的负 9 次方量级），
    /// 不改变 12% 语义边界。
    public static let accentCoverageTolerance: Double = 1e-9

    /// keylineOrangeA7A 亮侧定版色值的字节同源分量（与 MinisIconTokens
    /// 的已批准字面量同一算式：0xD9/0x77/0x07 ÷ 255），不复制为新的色值。
    /// 第 1 套配色（用户 11/17 选定）把亮侧强调色由 #D97707 换为陶土橙 #A84E2A。
    public static let keylineOrangeApprovedLightComponents =
        (r: Double(0xA8) / 255.0, g: Double(0x4E) / 255.0, b: Double(0x2A) / 255.0)

    /// 暗侧强调色 #E08B68（第 1 套深色强调）。
    public static let keylineOrangeApprovedDarkComponents =
        (r: Double(0xE0) / 255.0, g: Double(0x8B) / 255.0, b: Double(0x68) / 255.0)

    /// v1 全部条目，确定性顺序（目录身份 stable，便于逐值断言与记账）。
    public static let entries: [ThemePresetCatalogEntry] = [
        ThemePresetCatalogEntry(
            id: .keylineOrangeA7A,
            catalogVersion: version,
            acceptance: .acceptedForLight,
            lightAccent: ThemeColor(
                r: keylineOrangeApprovedLightComponents.r,
                g: keylineOrangeApprovedLightComponents.g,
                b: keylineOrangeApprovedLightComponents.b
            ),
            darkAccent: ThemeColor(
                r: keylineOrangeApprovedDarkComponents.r,
                g: keylineOrangeApprovedDarkComponents.g,
                b: keylineOrangeApprovedDarkComponents.b
            )
        ),
        ThemePresetCatalogEntry(
            id: .warmCoralA7A,
            catalogVersion: version,
            acceptance: .pendingColorMaterial,
            // 本头全仓零色板材料 → 两侧都不猜测。
            lightAccent: nil,
            darkAccent: nil
        ),
    ]

    public static func entry(for id: ThemePresetCatalogID) -> ThemePresetCatalogEntry? {
        entries.first { $0.id == id }
    }

    /// 当前可被 UI 选为真值的预设（亮侧已批准集合）。
    public static var selectableIDs: [ThemePresetCatalogID] {
        entries.filter { $0.acceptance == .acceptedForLight }.map(\.id)
    }

    /// dark / System 豁免裁决状态：唯一合法记录是 pending。本线不得自造规则。
    public static let darkBranchAdjudication: ThemePresetBranchAdjudication = .approved
    public static let systemBranchAdjudication: ThemePresetBranchAdjudication = .pending

    // MARK: 占比校验（可计算）

    /// 计算一组强调色涂抹区域的有效占比并对照 12% 上限。
    ///
    /// 失败关闭：任何非有限数、越界比例或区域总面积超过 1 的输入都会得到
    /// `.rejectedInvalidInput`，既不悄悄判过也不悄悄截断。空区域集合的
    /// 有效占比为 0，属上限内。
    public static func assessAccentCoverage(
        _ regions: [ThemeAccentPaintedRegion]
    ) -> ThemeAccentCoverageAssessment {
        var reasons = Set<ThemeAccentCoverageInvalidReason>()
        var totalArea = 0.0
        var effective = 0.0
        for region in regions {
            if !region.areaFraction.isFinite { reasons.insert(.areaFractionNotFinite) }
            if !region.paintOpacity.isFinite { reasons.insert(.paintOpacityNotFinite) }
            if region.areaFraction.isFinite,
               region.areaFraction < 0 || region.areaFraction > 1 {
                reasons.insert(.areaFractionOutOfRange)
            }
            if region.paintOpacity.isFinite,
               region.paintOpacity < 0 || region.paintOpacity > 1 {
                reasons.insert(.paintOpacityOutOfRange)
            }
            totalArea += region.areaFraction
            effective += region.areaFraction * region.paintOpacity
        }
        if totalArea.isFinite, totalArea > 1 + accentCoverageTolerance {
            reasons.insert(.totalAreaExceedsSurface)
        }
        if !reasons.isEmpty {
            return .rejectedInvalidInput(reasons: reasons.sorted())
        }
        if !effective.isFinite {
            return .rejectedInvalidInput(reasons: [.areaFractionNotFinite, .paintOpacityNotFinite].sorted())
        }
        if effective <= accentCoverageCeilingFraction + accentCoverageTolerance {
            return .withinCeiling(effectiveCoverage: effective)
        }
        return .exceedsCeiling(effectiveCoverage: effective)
    }
}

// MARK: - 旧值 → 新值迁移

/// 迁移结论（结构体而非可选项撒布，保证总量函数语义可被逐字段断言）。
public struct ThemePresetCatalogMigrationResult: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        /// 旧值被识别并迁移到新目录预设。
        case migrated
        /// 输入已经是当前目录规范存储值（幂等重放，不再改写）。
        case alreadyCurrent
        /// 输入不被识别：失败关闭，绝不悄悄回落默认值。
        case rejected
    }

    public let status: Status
    /// 迁移后的预设；rejected 时为 nil（不存在隐式默认）。
    public let presetID: ThemePresetCatalogID?
    /// 中性明暗分支；rejected / alreadyCurrent 时为 nil。
    public let branch: ThemePresetMigrationBranch?
    /// 当前目录的规范存储值（`preset.<id>`）；rejected 时为 nil。
    public let canonicalStoredValue: String?
    public let rejection: ThemePresetMigrationRejection?

    static func accepted(
        status: Status,
        presetID: ThemePresetCatalogID,
        branch: ThemePresetMigrationBranch?
    ) -> Self {
        Self(
            status: status,
            presetID: presetID,
            branch: branch,
            canonicalStoredValue: ThemePresetCatalogMigration.canonicalStoredValue(for: presetID),
            rejection: nil
        )
    }

    static func rejected(_ reason: ThemePresetMigrationRejection) -> Self {
        Self(
            status: .rejected,
            presetID: nil,
            branch: nil,
            canonicalStoredValue: nil,
            rejection: reason
        )
    }
}

/// 拒绝原因：显式、可断言，防止任何「未知即默认」的静默路径。
public enum ThemePresetMigrationRejection: String, Equatable, Sendable {
    case emptyStoredValue
    case malformedLegacyCombination
    case unknownAppearanceRawValue
    case unknownAccentRawValue
    case unknownStoredValue
}

/// 旧存储值 → 目录 v1 预设的全函数迁移。
///
/// 识别的旧值形态（与本头既有收敛工作的存储形态一致）：
/// 1. 「外观 × 主题色」组合字符串 `"<appearance>|<accent>"`
///    （即 3 × 6 = 18 种旧组合，与 ThemePresetConvergenceTests 的组合格式同源）；
/// 2. 旧 `ThemePreset` 存储值（light / dark / system / highContrast）；
/// 3. 当前目录规范值 `preset.<id>` 与裸目录 id（幂等重放通道）。
///
/// 全部被识别的旧值都收敛到 keylineOrangeA7A —— 本头唯一被批准具色的
/// 预设（唯一执行单 :230）；warmCoralA7A 不接收迁移流量（无批准色材料，
/// 路由到它等于自造语义）。明暗信息以中性分支字段保留：dark/System 的
/// 豁免结论待裁决，本迁移不裁决、不发明规则，只保证信息不丢失。
///
/// 总函数 + 失败关闭：接受任意 String，永不 throw、永不崩溃；未知输入
/// 返回 `.rejected`，不带任何预设值——不存在「坏了就悄悄给默认」路径。
/// 幂等：对任一非 rejected 结果，把它的 canonicalStoredValue 再次迁移，
/// 得到 alreadyCurrent 且预设与规范值逐字段不变。
public enum ThemePresetCatalogMigration {
    /// 当前目录规范存储值前缀。
    public static let canonicalStoredValuePrefix = "preset."
    /// 旧组合分隔符（与仓库既有组合身份格式 `"\(appearance)|\(accent)"` 一致）。
    public static let legacyCombinationSeparator: Character = "|"

    public static func canonicalStoredValue(for id: ThemePresetCatalogID) -> String {
        canonicalStoredValuePrefix + id.rawValue
    }

    /// 旧 18 组合的枚举总数（覆盖身份常数，测试端要求逐一对账）。
    public static var legacyCombinationCount: Int {
        Appearance.allCases.count * AccentTheme.allCases.count
    }

    /// 全函数入口，见类型注释。
    public static func migrate(storedValue raw: String) -> ThemePresetCatalogMigrationResult {
        // 1) 空值失败关闭。
        if raw.isEmpty {
            return .rejected(.emptyStoredValue)
        }

        // 2) 当前目录值（规范形态与裸 id）→ 幂等重放。
        if raw.hasPrefix(canonicalStoredValuePrefix) {
            let body = String(raw.dropFirst(canonicalStoredValuePrefix.count))
            if body.isEmpty {
                return .rejected(.unknownStoredValue)
            }
            guard let id = ThemePresetCatalogID(rawValue: body) else {
                return .rejected(.unknownStoredValue)
            }
            return .accepted(status: .alreadyCurrent, presetID: id, branch: nil)
        }
        if let id = ThemePresetCatalogID(rawValue: raw) {
            return .accepted(status: .alreadyCurrent, presetID: id, branch: nil)
        }

        // 3) 旧「外观|主题色」组合（18 种）。
        if raw.contains(legacyCombinationSeparator) {
            let components = raw.split(separator: legacyCombinationSeparator, omittingEmptySubsequences: false)
            if components.count != 2 {
                return .rejected(.malformedLegacyCombination)
            }
            let appearanceRaw = String(components[0])
            let accentRaw = String(components[1])
            if appearanceRaw.isEmpty || accentRaw.isEmpty {
                return .rejected(.malformedLegacyCombination)
            }
            guard let appearance = Appearance(rawValue: appearanceRaw) else {
                return .rejected(.unknownAppearanceRawValue)
            }
            guard AccentTheme(rawValue: accentRaw) != nil else {
                return .rejected(.unknownAccentRawValue)
            }
            // 主题色轴已被收敛（调色板唯一），明暗轴以中性分支字段保留。
            return .accepted(
                status: .migrated,
                presetID: .keylineOrangeA7A,
                branch: branch(for: appearance)
            )
        }

        // 4) ThemePreset 存储值：显式高对比保留其预设身份，不降级到暗色。
        if let legacyPreset = ThemePreset(rawValue: raw) {
            let branch: ThemePresetMigrationBranch
            switch legacyPreset {
            case .light: branch = .fixedLight
            case .dark: branch = .fixedDark
            case .system: branch = .systemMirror
            case .highContrast: branch = .fixedHighContrast
            }
            return .accepted(
                status: .migrated,
                presetID: .keylineOrangeA7A,
                branch: branch
            )
        }

        // 5) 其余一切：失败关闭，绝不静默默认。
        return .rejected(.unknownStoredValue)
    }

    private static func branch(for appearance: Appearance) -> ThemePresetMigrationBranch {
        switch appearance {
        case .light: .fixedLight
        case .dark: .fixedDark
        case .system: .systemMirror
        }
    }
}
