import Foundation
import Testing
@testable import MinisCore

@Suite("UX-01 Typography settings")
struct TypographySettingsTests {

    private func makeTempDir(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UX01-Typography-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func baseFontSizeUsesTheSpecifiedRangeAndStep() {
        #expect(TypographySettings.uiBaseFontSizeRange == 12...20)
        #expect(TypographySettings.uiBaseFontSizeStep == 1)
        #expect(Array(TypographySettings.uiBaseFontSizeRange) == [12, 13, 14, 15, 16, 17, 18, 19, 20])
    }

    @Test func defaultsUse14PointBaseFontSize() {
        #expect(TypographySettings.default.uiBaseFontSize == 14)
        #expect(AppSettings.defaults.typography.uiBaseFontSize == 14)
    }

    @Test func valuesOutsideTheRangeAreClamped() {
        #expect(TypographySettings(uiBaseFontSize: 11).uiBaseFontSize == 12)
        #expect(TypographySettings(uiBaseFontSize: 21).uiBaseFontSize == 20)
        #expect(TypographySettings(uiBaseFontSize: 12).uiBaseFontSize == 12)
        #expect(TypographySettings(uiBaseFontSize: 20).uiBaseFontSize == 20)
    }

    @Test func semanticTokensMapEverySupportedBaseSizeDeterministically() {
        for size in TypographySettings.uiBaseFontSizeRange {
            let tokens = TypographyTokenSet.forBaseFontSize(size)
            let base = Double(size)

            #expect(tokens.baseFontSize == size)
            #expect(tokens.size(for: .body) == base)
            #expect(tokens.size(for: .headline) == base + 2)
            #expect(tokens.size(for: .caption) == max(11, base - 2))
            #expect(tokens.size(for: .caption2) == max(10, base - 3))
            #expect(tokens.size(for: .sidebarTitle) == base + 1)
            #expect(tokens.size(for: .sidebarItem) == base)
            #expect(tokens.size(for: .sidebarMeta) == max(11, base - 2))
            #expect(tokens.size(for: .transcriptBody) == base)
            #expect(tokens.size(for: .composerBody) == base)
            #expect(tokens.size(for: .status) == max(11, base - 2))
            #expect(tokens.size(for: .toolbar) == 12)
            #expect(tokens.size(for: .dangerousAction) == 12)
        }
    }

    @Test func semanticRolesKeepDistinctHierarchyAtEverySupportedBaseSize() {
        // F14/D-SETTINGS-22: the previous 12pt floors collapsed body, caption,
        // sidebar meta and status onto one size at bases 12-13. Every role
        // step must stay visible across the whole configurable range.
        for size in TypographySettings.uiBaseFontSizeRange {
            let tokens = TypographyTokenSet.forBaseFontSize(size)
            #expect(tokens.size(for: .headline) > tokens.size(for: .sidebarTitle))
            #expect(tokens.size(for: .sidebarTitle) > tokens.size(for: .body))
            #expect(tokens.size(for: .body) == tokens.size(for: .transcriptBody))
            #expect(tokens.size(for: .body) == tokens.size(for: .composerBody))
            #expect(tokens.size(for: .body) == tokens.size(for: .monospaced))
            #expect(tokens.size(for: .body) == tokens.size(for: .sidebarItem))
            #expect(tokens.size(for: .body) > tokens.size(for: .caption))
            #expect(tokens.size(for: .body) > tokens.size(for: .sidebarMeta))
            #expect(tokens.size(for: .body) > tokens.size(for: .status))
            #expect(tokens.size(for: .caption) == tokens.size(for: .sidebarMeta))
            #expect(tokens.size(for: .caption) == tokens.size(for: .status))
            #expect(tokens.size(for: .caption) > tokens.size(for: .caption2))
        }
    }

    @Test func semanticTokenResolutionClampsUntrustedBaseSizes() {
        #expect(TypographyTokenSet.forBaseFontSize(0).baseFontSize == 12)
        #expect(TypographyTokenSet.forBaseFontSize(99).baseFontSize == 20)
    }

    @Test func directStoreUpdatesClampBeforeTheyPersist() throws {
        let dir = try makeTempDir("mutation-clamp")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SettingsStore(directory: dir)
        store.update(\.typography.uiBaseFontSize, to: 99)
        #expect(store.settings.typography.uiBaseFontSize == 20)

        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.settings.typography.uiBaseFontSize == 20)

        store.update(\.typography.uiBaseFontSize, to: -1)
        #expect(store.settings.typography.uiBaseFontSize == 12)
    }

    @Test func supportedSizesRoundTripThroughAppSettings() throws {
        for size in [12, 14, 16, 18, 20] {
            var settings = AppSettings.defaults
            settings.typography.uiBaseFontSize = size

            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
            #expect(decoded.typography.uiBaseFontSize == size)
        }
    }

    @Test func baseFontSizePersistsAcrossSettingsStoreInstances() throws {
        let dir = try makeTempDir("persistence")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SettingsStore(directory: dir)
        store.update(\.typography.uiBaseFontSize, to: 18)

        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.settings.typography.uiBaseFontSize == 18)
    }

    @Test func v2SettingsMigrateToCurrentSchemaWithDefaultTypography() throws {
        let json = """
        {
          "settingsVersion": 2,
          "general": { "appearance": "dark", "language": "zh-Hans" },
          "agent": { "maxLoopIterations": 5 }
        }
        """

        let result = try SettingsMigration.migrate(data: Data(json.utf8))
        #expect(result.migrated)
        #expect(result.settings.settingsVersion == AppSettings.currentVersion)
        #expect(result.settings.typography.uiBaseFontSize == 14)
        #expect(result.settings.general.themePreset == .system)
        #expect(result.settings.general.appearance == .system)
        #expect(result.settings.general.legacyThemePresetRawValue == "dark|pseudo")
        #expect(result.settings.agent.maxLoopIterations == 5)
        let reopened = try SettingsMigration.migrate(data: JSONEncoder().encode(result.settings))
        #expect(!reopened.migrated)
        #expect(reopened.settings == result.settings)
    }

    @Test func resetToDefaultsRestoresAndPersistsDefaultTypography() throws {
        let dir = try makeTempDir("reset")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SettingsStore(directory: dir)
        store.update(\.typography.uiBaseFontSize, to: 20)
        store.resetToDefaults()

        #expect(store.settings.typography.uiBaseFontSize == 14)
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.settings.typography.uiBaseFontSize == 14)
    }
}
