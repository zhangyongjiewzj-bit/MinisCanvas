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
        // 伪仙赭橙 RGB：暗色 #A0613C ≈ (0.627, 0.380, 0.235)。
        let rgb = AccentTheme.pseudo.accentRGB
        #expect(abs(rgb.r - 0.627) < 0.001)
        #expect(abs(rgb.g - 0.380) < 0.001)
        #expect(abs(rgb.b - 0.235) < 0.001)
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
        #expect(decoded.general.themePreset == .system)
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
        #expect(store.settings.general.themePreset == .system)
        #expect(store.settings.general.accentTheme == .pseudo)
        #expect(store.settings.general.legacyThemePresetRawValue == "system|ocean")
        guard case .success = store.update(\.general.themePreset, to: .light) else {
            Issue.record("当前产品主题必须经真实 SettingsStore 成功持久化")
            return
        }
        #expect(store.settings.general.themePreset == .light)

        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.settings.general.themePreset == .light)
        #expect(reloaded.settings.general.accentTheme == .pseudo)
        #expect(reloaded.settings.general.appearance == .light)
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
