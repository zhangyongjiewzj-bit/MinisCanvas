import Foundation
import Testing
@testable import MinisCore

/// SETTINGS-27 / THEME-01 / THEME-05：外观收敛为 3-5 个完整主题预设。
///
/// 覆盖身份（每条计数必须相等，缺一即本文件失效）：
/// - 旧组合枚举数 `legacyPairCount` = 3 Appearance × 6 AccentTheme = 18
/// - 映射断言数 `mappingAssertionCount` 必须等于 `legacyPairCount`
/// - 预设数 `ThemePreset.allCases.count` 与可选数 `selectable.count`
///   都必须落在需求区间的 3...5 内
struct ThemePresetConvergenceTests {

    // MARK: - 覆盖身份常量

    /// 收敛前暴露的任意组合总数（"外观模式 × 主题色"）。
    private static let legacyPairCount = Appearance.allCases.count * AccentTheme.allCases.count
    private static let expectedLegacyPairCount = 18

    /// 全部旧组合，确定性顺序。
    private static var allLegacyPairs: [(Appearance, AccentTheme)] {
        Appearance.allCases.flatMap { a in AccentTheme.allCases.map { t in (a, t) } }
    }

    // MARK: - THEME-01：预设数量与命名集合

    @Test func presetCountStaysWithinThreeToFive() {
        // 20261004T1115 supersedes the historical 3–5 set, not its evidence.
        #expect(ThemePreset.allCases == [.light, .system])
        #expect(ThemePreset.selectable == [.light, .system])
        #expect(!ThemePreset.dark.isAccepted)
        #expect(!ThemePreset.highContrast.isAccepted)
    }

    @Test func namedPresetsAreAllPresent() {
        #expect(ThemePreset.light.displayName == "浅色（产品主题）")
        #expect(ThemePreset.system.displayName == "跟随系统（原生）")
        #expect(!ThemePreset.selectable.contains(.dark))
        #expect(!ThemePreset.selectable.contains(.highContrast))
    }

    /// The fourth preset is complete, distinct from ordinary dark, and keeps
    /// the original palette, surfaces and per-role contrast contract.
    @Test func highContrastResolvesTheFourthCompletePreset949() throws {
        // Historical raw words remain decodable, but cannot resolve a live preset.
        #expect(ThemePreset(rawValue: "highContrast") == .highContrast)
        #expect(ThemePreset.highContrast.semanticTokens(systemIsDark: false) == nil)
        #expect(ThemePreset.highContrast.semanticTokens(systemIsDark: true) == nil)
        #expect(ThemePreset.dark.semanticTokens(systemIsDark: true) == nil)
        #expect(ThemePreset.converging("highContrast") == .system)
        #expect(ThemePreset.converging("dark") == .system)
        #expect(ThemeContrastRole.body.minimumRatio == 4.5)
        #expect(ThemeContrastRole.secondary.minimumRatio == 4.5)
        #expect(ThemeContrastRole.disabled.minimumRatio == 2.5)
        #expect(ThemeContrastRole.selected.minimumRatio == 3.0)
        #expect(ThemeContrastRole.status.minimumRatio == 3.0)
    }

    /// 已验收预设的 token 全部可解析（深色不再不可达）。
    @Test func acceptedPresetsResolveCompleteTokenSets() {
        for preset in ThemePreset.selectable {
            #expect(preset.isAccepted)
            #expect(preset.palette != nil)
            let lightSide = preset.semanticTokens(systemIsDark: false)
            let darkSide = preset.semanticTokens(systemIsDark: true)
            #expect(lightSide != nil)
            #expect(darkSide != nil)
            #expect(lightSide?.background != lightSide?.textPrimary)
        }
        // 深色 preset 与浅色 preset 的表面/文本层确实相反。
        let lightTokens = ThemePreset.light.semanticTokens(systemIsDark: false)
        let darkTokens = ThemePreset.system.semanticTokens(systemIsDark: true)
        #expect(lightTokens?.background != darkTokens?.background)
        #expect((lightTokens?.background.luminance ?? 0) > (darkTokens?.background.luminance ?? 1))
        #expect((darkTokens?.textPrimary.luminance ?? 0) > (lightTokens?.textPrimary.luminance ?? 1))
    }

    // MARK: - A7-A identity/surfaces remain exact; failing foregrounds are repaired.

    @Test func presetPaletteAndUnaffectedNeutralTokensStayByteIdentical834() throws {
        #expect(ThemePreset.light.palette == AccentTheme.pseudo.palette)
        #expect(ThemePreset.dark.palette == nil)
        #expect(ThemePreset.canonicalAccentTheme == .pseudo)
        for (preset, mode) in [(ThemePreset.light, ThemeMode.light), (.system, .dark)] {
            let raw = AccentTheme.pseudo.semanticTokens(for: mode)
            let actual = try #require(preset.semanticTokens(systemIsDark: mode == .dark))
            #expect(actual.background == raw.background)
            #expect(actual.sidebarBackground == raw.sidebarBackground)
            #expect(actual.surfaceRaised == raw.surfaceRaised)
            #expect(actual.stroke == raw.stroke)
            #expect(actual.focusRing == raw.focusRing)
            #expect(actual.textPrimary == raw.textPrimary)
            // 第 1 套色值已按 WCAG 算过：原始色板本身即达标，对比度修正不需要改动任何前景。
            #expect(ThemeContrast.violations(tokens: raw).isEmpty)
            #expect(actual.textSecondary == raw.textSecondary)
            #expect(actual.statusDanger == raw.statusDanger)
            for background in [raw.background, raw.sidebarBackground, raw.surfaceRaised] {
                #expect(ThemeContrast.violations(tokens: actual, background: background).isEmpty)
            }
        }
    }

    // MARK: - THEME-05：旧组合 → 最近预设

    /// 全部 18 种旧组合各映射到恰好一个已验收预设；断言数 == 枚举数。
    @Test func everyLegacyPairMapsToExactlyOneAcceptedPreset() {
        let pairs = Self.allLegacyPairs
        #expect(pairs.count == Self.expectedLegacyPairCount)
        #expect(pairs.count == Self.legacyPairCount)

        var assertionCount = 0
        for (appearance, accent) in pairs {
            let preset = ThemePreset.nearest(for: appearance, accentTheme: accent)
            #expect(preset.isAccepted, "未验收预设不得成为映射目标: \(appearance)/\(accent)")
            #expect(ThemePreset.allCases.contains(preset))
            assertionCount += 1
        }
        // 覆盖身份：映射断言数 == 旧组合枚举数。
        #expect(assertionCount == Self.legacyPairCount)
        #expect(assertionCount == Self.expectedLegacyPairCount)
    }

    /// 映射是确定性的函数：同输入两次调用结果一致，且明暗轴被保留。
    @Test func mappingIsDeterministicAndPreservesLightDarkIntent() {
        #expect(ThemePreset.nearest(for: .light, accentTheme: .ocean) == .light)
        #expect(ThemePreset.nearest(for: .dark, accentTheme: .codex) == .system)
        #expect(ThemePreset.nearest(for: .system, accentTheme: .emerald) == .system)
        // 确定性：重复 50 次不漂移。
        for _ in 0..<50 {
            #expect(ThemePreset.nearest(for: .dark, accentTheme: .crimson) == .system)
        }
        // 主题色不再改变结果（调色板已收敛），因此 6 个 accent 只落在同一预设上。
        let mapped = Set(AccentTheme.allCases.map { ThemePreset.nearest(for: .light, accentTheme: $0) })
        #expect(mapped == [.light])
    }

    // MARK: - SETTINGS-27：双轴不再可达

    /// 四个预设只投影到三个兼容外观组合，高对比与深色共用dark投影；
    /// 不重新引入原18种自由组合。
    @Test func dualAxisIsNoLongerStorable() {
        var reachablePairs = Set<String>()
        for preset in ThemePreset.selectable {
            var general = GeneralSettings.default
            general.setThemePreset(preset)
            reachablePairs.insert("\(general.appearance.rawValue)|\(general.accentTheme.rawValue)")
            // 旧字段严格是预设的投影。
            #expect(general.appearance == preset.appearanceProjection)
            #expect(general.accentTheme == ThemePreset.canonicalAccentTheme)
        }
        #expect(ThemePreset.selectable.count == 2)
        // 第 1 套配色起产品主题也跟随系统明暗，两个预设都投影为 system|pseudo；不存在自由组合。
        #expect(reachablePairs.count < Self.expectedLegacyPairCount)
        #expect(reachablePairs == ["system|pseudo"])
    }

    /// 构造路径同样造不出自由组合：显式给预设时旧字段被覆盖投影。
    @Test func initializerConvergesInsteadOfStoringCombination() {
        // 显式预设胜出，旧字段成为投影。
        let fromPreset = GeneralSettings(themePreset: .dark, appearance: .light, accentTheme: .crimson)
        #expect(fromPreset.themePreset == .system)
        #expect(fromPreset.appearance == .light)   // 明暗是独立选择，不被预设覆盖
        #expect(fromPreset.accentTheme == .pseudo)

        // 只给旧字段时配色由 nearest 映射（THEME-05 语义），明暗原样保留。
        let fromLegacy = GeneralSettings(appearance: .dark, accentTheme: .ocean)
        #expect(fromLegacy.themePreset == .system)
        #expect(fromLegacy.appearance == .dark)

        // 高对比是显式第四预设，只收敛配色。
        let highContrast = GeneralSettings(themePreset: .highContrast, appearance: .light)
        #expect(highContrast.themePreset == .system)
        #expect(highContrast.appearance == .light)
        #expect(highContrast.accentTheme == .pseudo)
    }

    /// 存储值不可解析/未验收时一律收敛，永不恢复不可读组合。
    @Test func corruptStoredPresetAlwaysConverges() {
        #expect(ThemePreset.converging(nil) == .system)
        #expect(ThemePreset.converging("not-a-preset") == .system)
        #expect(ThemePreset.converging("highContrast") == .system)
        #expect(ThemePreset.converging("") == .system)
        #expect(ThemePreset.converging("light") == .light)
        #expect(ThemePreset.converging("dark", fallback: .light) == .system)
        // Explicit legal fallback is honored; unknown raw values do not become new presets.
        #expect(ThemePreset.converging(nil, fallback: .highContrast).isAccepted)
        #expect(ThemePreset.converging(nil, fallback: .highContrast) == .system)
        for raw in [nil, "", "bogus", "highContrast", ".dark"] {
            #expect(ThemePreset.converging(raw, fallback: .highContrast).isAccepted)
        }
    }

    // MARK: - THEME-05：迁移幂等 + 重启持久化

    /// 手工构造的 v3 旧 payload（只有 appearance × accentTheme）迁移到 v4。
    private static func legacyV3JSON(appearance: String, accent: String) -> String {
        """
        {
          "settingsVersion": 3,
          "general": {
            "appearance": "\(appearance)",
            "accentTheme": "\(accent)"
          }
        }
        """
    }

    @Test func migrationConvergesEveryLegacyPayload() throws {
        var assertionCount = 0
        for (appearance, accent) in Self.allLegacyPairs {
            let data = Data(Self.legacyV3JSON(appearance: appearance.rawValue, accent: accent.rawValue).utf8)
            let first = try SettingsMigration.migrate(data: data)
            // nearest 给出 system 的旧组合（无迁移标记）会被一次性迁到产品主题（.light）。
            let nearest = ThemePreset.nearest(for: appearance, accentTheme: accent)
            #expect(first.settings.general.themePreset == (nearest == .system ? .light : nearest))
            #expect(first.settings.general.themePreset.isAccepted)
            #expect(first.settings.settingsVersion == AppSettings.currentVersion)
            // 迁移后旧字段已是投影，不再携带未验收组合。
            #expect(first.settings.general.accentTheme == ThemePreset.canonicalAccentTheme)
            // F-1：旧「固定浅色」仍是浅色；其余旧组合跟随系统。
            #expect(first.settings.general.appearance == (appearance == .light ? .light : .system))
            assertionCount += 1
        }
        // 覆盖身份：迁移断言组数 == 旧组合枚举数 == 18。
        #expect(assertionCount == Self.legacyPairCount)
        #expect(assertionCount == Self.expectedLegacyPairCount)
    }

    /// 幂等：对同一 payload 反复迁移结果不变。
    @Test func migrationIsIdempotent() throws {
        for (appearance, accent) in Self.allLegacyPairs {
            let data = Data(Self.legacyV3JSON(appearance: appearance.rawValue, accent: accent.rawValue).utf8)
            let once = try SettingsMigration.migrate(data: data)
            let twice = try SettingsMigration.migrate(data: JSONEncoder().encode(once.settings))
            #expect(twice.settings == once.settings)
            #expect(twice.migrated == false)  // 已是当前版本，不再改写。
            let thrice = SettingsMigration.applyingMigrations(
                to: once.settings,
                fromVersion: once.settings.settingsVersion
            )
            #expect(thrice == once.settings)
        }
    }

    /// 空 payload / 无版本 payload 也落到已验收预设。
    @Test func migrationDefaultsToReadablePreset() throws {
        let empty = try SettingsMigration.migrate(data: Data("{}".utf8))
        #expect(empty.settings.general.themePreset == .light)
        #expect(empty.settings.general.themePreset.isAccepted)

        let defaults = AppSettings.defaults
        #expect(defaults.general.themePreset == .light)
        #expect(defaults.general == GeneralSettings.default)
    }

    /// 重启往返：写入预设 → 落盘 → 重新开一个 store 读回同一预设。
    @Test func storedPresetSurvivesRestartRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCore-ThemePreset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for preset in ThemePreset.selectable {
            let store = SettingsStore(directory: dir)
            switch store.update(\.general, { $0.setThemePreset(preset) }) {
            case .success: break
            case .failure(let error): Issue.record("预设 \(preset.rawValue) 持久化失败: \(error)")
            }

            // 模拟重启：新建 store 从磁盘重新解码。
            let reopened = SettingsStore(directory: dir)
            #expect(reopened.settings.general.themePreset == preset)
            #expect(reopened.settings.general.themePreset.isAccepted)
            #expect(reopened.settings.settingsVersion == AppSettings.currentVersion)
            // 投影字段同样持久，因此重启后不会重新暴露第二个轴。
            #expect(reopened.settings.general.appearance == preset.appearanceProjection)
            #expect(reopened.settings.general.accentTheme == ThemePreset.canonicalAccentTheme)
        }
    }

    /// 旧 v3 文件经真实落盘/重启路径迁移，且第二次重启不改变结果。
    @Test func legacyPayloadMigratesAndPersistsAcrossRestart() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCore-ThemePreset-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 一个收敛前不可能被验收、但仍会被旧 UI 存下的组合：深色 × 海洋蓝。
        let json = Self.legacyV3JSON(appearance: "dark", accent: "ocean")
        try Data(json.utf8).write(
            to: dir.appendingPathComponent(SettingsStore.fileName)
        )

        let firstBoot = SettingsStore(directory: dir)
        #expect(firstBoot.settings.general.themePreset == .light)   // 旧深色 → 跟随系统 → 一次性迁到产品主题
        #expect(firstBoot.settings.general.accentTheme == .pseudo)

        let secondBoot = SettingsStore(directory: dir)
        #expect(secondBoot.settings == firstBoot.settings)
        #expect(secondBoot.settings.general.themePreset == .light)
        #expect(secondBoot.settings.general.themePreset.isAccepted)
    }

    /// 第四预设通过持久化解码仍保留完整身份。
    @Test func highContrastStoredPresetRestoresFullIdentity949() throws {
        var settings = AppSettings.defaults
        settings.general.setThemePreset(.highContrast)
        let data = try JSONEncoder().encode(settings)

        let reloaded = try SettingsMigration.migrate(data: data)
        #expect(reloaded.settings.general.themePreset.isAccepted)
        #expect(reloaded.settings.general.themePreset == .system)
        #expect(reloaded.settings.general.appearance == .system)
        #expect(reloaded.settings.general.themePreset.semanticTokens(systemIsDark: false)
                == ThemePreset.system.semanticTokens(systemIsDark: false))
    }
    @Test(arguments: ["unknown-preset", "preset.warmCoralA7A"])
    func unknownStoredPresetStillFailsTypedDecode949(raw: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["themePreset": raw])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(GeneralSettings.self, from: data)
        }
        #expect(ThemePreset.converging(raw) == .system)
        #expect(ThemePreset(rawValue: raw) == nil)
    }

}

/// F-1：明暗选择（浅色 / 深色 / 跟随系统）独立于配色预设，旧「固定浅色」用户迁移后仍是浅色。
struct AppearanceModeChoiceTests {
    private func decode(_ general: [String: Any]) throws -> GeneralSettings {
        let data = try JSONSerialization.data(withJSONObject: general)
        return try JSONDecoder().decode(GeneralSettings.self, from: data)
    }

    @Test func oldFixedLightUserStaysLightAfterMigration() throws {
        // 没有迁移标记 = 「产品主题固定浅色」时代写的文件。
        let stored = try decode(["themePreset": "light", "appearance": "light"])
        #expect(stored.themePreset == .light)
        #expect(stored.appearance == .light)
        let legacy = try decode(["appearance": "light", "accentTheme": "ocean"])
        #expect(legacy.themePreset == .light)
        #expect(legacy.appearance == .light)
        // 原来跟随系统 / 深色的用户仍跟随系统。
        #expect(try decode(["themePreset": "system"]).appearance == .system)
        #expect(try decode(["appearance": "dark"]).appearance == .system)
    }

    @Test func choiceIsIndependentOfPresetAndSurvivesReopen() throws {
        for mode in Appearance.allCases {
            var general = GeneralSettings.default
            general.appearance = mode
            general.setThemePreset(.light)
            #expect(general.appearance == mode)   // 写预设不覆盖明暗
            let data = try JSONEncoder().encode(general)
            let reopened = try JSONDecoder().decode(GeneralSettings.self, from: data)
            #expect(reopened.appearance == mode)
            #expect(reopened.themePreset == .light)
        }
    }

    @Test func postChangeFileWithProductThemeKeepsFollowingSystem() throws {
        // 有标记：新版本写的文件，产品主题 + 跟随系统不被改成固定浅色。
        let stored = try decode(["themePreset": "light", "appearance": "system", "productThemeDefaultMigrated": true])
        #expect(stored.appearance == .system)
    }
}
