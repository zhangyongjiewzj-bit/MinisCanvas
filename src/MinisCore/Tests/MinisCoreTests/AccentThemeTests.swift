import Foundation
import Testing
@testable import MinisCore

/// E13 主题多模式：AccentTheme 枚举完备性 + AppSettings 默认值/迁移。
struct AccentThemeTests {

    // MARK: - 枚举完备

    @Test func allThemesPresent() {
        #expect(AccentTheme.allCases.count == 6)
        #expect(Set(AccentTheme.allCases.map(\.rawValue)) == ["pseudo", "codex", "graphite", "ocean", "crimson", "emerald"])
    }

    @Test func everyThemeHasRGBInRangeAndDisplayName() {
        for theme in AccentTheme.allCases {
            let rgb = theme.accentRGB
            #expect((0.0...1.0).contains(rgb.r))
            #expect((0.0...1.0).contains(rgb.g))
            #expect((0.0...1.0).contains(rgb.b))
            #expect(!theme.displayName.isEmpty)
            #expect(!theme.rawValue.isEmpty)
        }
    }

    @Test func darkPreferredSplitMatchesSpec() {
        // 深色优先：codex / graphite；浅色优先：ocean / crimson / emerald。
        #expect(AccentTheme.codex.prefersDark)
        #expect(AccentTheme.graphite.prefersDark)
        #expect(!AccentTheme.ocean.prefersDark)
        #expect(!AccentTheme.crimson.prefersDark)
        #expect(!AccentTheme.emerald.prefersDark)
    }

    @Test func themesAreDistinct() {
        // 5 套主题色互不相同。
        let colors = Set(AccentTheme.allCases.map { "\($0.accentRGB.r),\($0.accentRGB.g),\($0.accentRGB.b)" })
        #expect(colors.count == AccentTheme.allCases.count)
    }

    @Test func rawValueRoundTrip() {
        for theme in AccentTheme.allCases {
            #expect(AccentTheme(rawValue: theme.rawValue) == theme)
        }
    }

    // MARK: - AppSettings 默认值

    @Test func defaultAccentThemeIsPseudo() {
        #expect(AppSettings.defaults.general.accentTheme == .pseudo)
        #expect(GeneralSettings.default.accentTheme == .pseudo)
        // 第 1 套陶土橙：浅色 #A84E2A ≈ (0.659, 0.306, 0.165)；深色 #E08B68 ≈ (0.878, 0.545, 0.408)。
        let rgb = AccentTheme.pseudo.accentRGB
        #expect(abs(rgb.r - 0.659) < 0.001)
        #expect(abs(rgb.g - 0.306) < 0.001)
        #expect(abs(rgb.b - 0.165) < 0.001)
        let dark = AccentTheme.pseudo.darkAccentRGB
        #expect(abs(dark.r - 0.878) < 0.001)
        #expect(abs(dark.g - 0.545) < 0.001)
        #expect(abs(dark.b - 0.408) < 0.001)
        // 默认主题 = 产品主题（需披露的变更）。
        #expect(GeneralSettings.default.themePreset == .light)
    }

    @Test func savedSystemPresetMigratesOnceToProductThemeThenSticks() throws {
        // 旧文件存的是「跟随系统」且没有迁移标记 → 迁到产品主题一次。
        let legacy = #"{"settingsVersion":4,"general":{"themePreset":"system"}}"#
        let migrated = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        #expect(migrated.general.themePreset == .light)
        // 用户之后手动切回「跟随系统」：保存时带标记，再读不会被改。
        var chosen = migrated
        chosen.general.setThemePreset(.system)
        let reopened = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(chosen))
        #expect(reopened.general.themePreset == .system)
    }

    // MARK: - 迁移：旧 JSON 无 accentTheme → 默认 .pseudo

    @Test func oldJSONWithoutAccentThemeFallsBackToPseudo() throws {
        // v2 时代 JSON（无 accentTheme 字段）。
        let json = """
        {
          "settingsVersion": 2,
          "general": { "appearance": "dark", "language": "en" },
          "agent": { "maxLoopIterations": 5 }
        }
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.general.accentTheme == .pseudo)
        // 1115 两主题决定：退休外观只保留迁移来源，不再成为生效值。
        // 旧「深色」→ 跟随系统 → 一次性迁移到产品主题（带深色版，明暗跟随系统）。
        #expect(decoded.general.themePreset == .light)
        #expect(decoded.general.appearance == .system)
        #expect(decoded.general.legacyThemePresetRawValue == "dark|pseudo")
        let reopened = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(decoded))
        #expect(reopened.general == decoded.general)
        #expect(decoded.settingsVersion == 2)
        #expect(decoded.agent.maxLoopIterations == 5)
    }

    @Test func storeLoadsOldJSONWithPseudoDefault() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("E13AccentTheme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let json = """
        { "settingsVersion": 2, "general": { "appearance": "light" } }
        """
        let fileURL = dir.appendingPathComponent(SettingsStore.fileName)
        try Data(json.utf8).write(to: fileURL)

        let store = SettingsStore(directory: dir)
        #expect(store.settings.general.accentTheme == .pseudo)
        // F-1（2026-11-17）：明暗与配色分开；旧文件里固定浅色的用户迁移后仍是浅色。
        #expect(store.settings.general.themePreset == .light)
        #expect(store.settings.general.appearance == .light)
    }

    // MARK: - 显式旧值 provenance 与当前预设 round-trip 持久化

    @Test func explicitAccentThemePersistsAcrossReload() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("E13AccentThemeRoundtrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 原 E13 ocean 是历史输入。当前 UI 只通过唯一 themePreset 写入口选择。
        let legacy = #"{"settingsVersion":3,"general":{"appearance":"system","accentTheme":"ocean"}}"#
        try Data(legacy.utf8).write(to: dir.appendingPathComponent(SettingsStore.fileName))
        let store = SettingsStore(directory: dir)
        // 旧文件存的是跟随系统且没有迁移标记 → 一次性迁到产品主题。
        #expect(store.settings.general.themePreset == .light)
        #expect(store.settings.general.accentTheme == .pseudo)
        #expect(store.settings.general.legacyThemePresetRawValue == "system|ocean")
        guard case .success = store.update(\.general.themePreset, to: .system) else {
            Issue.record("用户手动切回跟随系统必须经真实 SettingsStore 成功持久化")
            return
        }
        #expect(store.settings.general.themePreset == .system)

        // 重新打开：迁移标记已写入，用户的手动选择不再被改回产品主题。
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.settings.general.themePreset == .system)
        #expect(reloaded.settings.general.accentTheme == .pseudo)
        #expect(reloaded.settings.general.appearance == .system)
        #expect(reloaded.settings.general.legacyThemePresetRawValue == "system|ocean")
        #expect(reloaded.settings.general == store.settings.general)
    }

    @Test func accentThemeCodableRoundTrip() throws {
        for theme in AccentTheme.allCases {
            let data = try JSONEncoder().encode(theme)
            let decoded = try JSONDecoder().decode(AccentTheme.self, from: data)
            #expect(decoded == theme)
        }
    }
}
