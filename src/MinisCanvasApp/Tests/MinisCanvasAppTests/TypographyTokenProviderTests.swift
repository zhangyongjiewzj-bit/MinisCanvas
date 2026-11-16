import Foundation
import Testing
import SwiftUI
import MinisCore
@testable import MinisCanvasApp

@Suite("UX-01 Typography token provider")
@MainActor
struct TypographyTokenProviderTests {

    private func makeCenter() throws -> (SettingsCenter, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UX01-Typography-App-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: dir),
            envStore: EnvVarStore(directory: dir),
            memoryStore: MemoryStore(directory: dir),
            sessionStore: SessionStore(directory: dir),
            logManager: LogManager(directory: dir, ringCapacity: 50)
        )
        return (center, dir)
    }

    @Test func settingsCenterBindsAndPersistsTheBaseFontSize() throws {
        let (center, dir) = try makeCenter()
        defer { try? FileManager.default.removeItem(at: dir) }

        center.uiBaseFontSize = 18
        #expect(center.uiBaseFontSize == 18)
        #expect(center.settingsStore.settings.typography.uiBaseFontSize == 18)

        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.settings.typography.uiBaseFontSize == 18)
    }

    @Test func providerTracksEverySupportedBaseFontSize() throws {
        let (center, dir) = try makeCenter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = TypographyTokenProvider(center: center)

        for size in [12, 14, 16, 18, 20] {
            center.uiBaseFontSize = size
            #expect(provider.baseFontSize == CGFloat(size))
            #expect(provider.bodySize == CGFloat(size))
            #expect(provider.headlineSize == CGFloat(size + 2))
            #expect(provider.monospacedSize == CGFloat(size))
            #expect(provider.metricSize == CGFloat(size + 2))
            #expect(provider.captionSize == CGFloat(max(11, size - 2)))
            #expect(provider.caption2Size == CGFloat(max(10, size - 3)))
            #expect(provider.transcriptBodySize == CGFloat(size))
            #expect(provider.composerBodySize == CGFloat(size))
            #expect(provider.transcriptBodySize(for: .medium) == CGFloat(size))
            #expect(
                abs(provider.transcriptBodySize(for: .large) - CGFloat(size) * 14 / 13) < 0.0001
            )
        }
    }

    @Test func providerKeepsSecondaryRolesDistinctAtTheSmallestSize() throws {
        let (center, dir) = try makeCenter()
        defer { try? FileManager.default.removeItem(at: dir) }
        center.uiBaseFontSize = 12
        let provider = TypographyTokenProvider(center: center)

        // F14/D-SETTINGS-22: secondary roles used to collapse onto the body
        // size at 12pt; each step must stay visible.
        #expect(provider.sidebarTitleSize == 13)
        #expect(provider.sidebarItemSize == 12)
        #expect(provider.sidebarMetaSize == 11)
        #expect(provider.statusSize == 11)
        #expect(provider.captionSize == 11)
        #expect(provider.caption2Size == 10)
    }

    @Test func contentScaleTracksThePersistedBaseSize() throws {
        let (center, dir) = try makeCenter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = TypographyTokenProvider(center: center)

        center.uiBaseFontSize = 14
        #expect(provider.contentScale == 1)
        center.uiBaseFontSize = 16
        #expect(provider.contentScale == 16.0 / 14.0)
        center.uiBaseFontSize = 12
        #expect(provider.contentScale == 12.0 / 14.0)
        center.uiBaseFontSize = 20
        #expect(provider.contentScale == 20.0 / 14.0)
    }

    @Test func roleAccessorResolvesEverySemanticRoleThroughTheSharedMap() throws {
        let (center, dir) = try makeCenter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = TypographyTokenProvider(center: center)

        for size in [12, 14, 16, 20] {
            center.uiBaseFontSize = size
            #expect(provider.font(for: .body) == provider.body)
            #expect(provider.font(for: .headline) == provider.headline)
            #expect(provider.font(for: .caption) == provider.caption)
            #expect(provider.font(for: .caption2) == provider.caption2)
            #expect(provider.font(for: .monospaced) == provider.monospaced)
            #expect(provider.font(for: .metric) == provider.metric)
            #expect(provider.font(for: .sidebarTitle) == provider.sidebarTitle)
            #expect(provider.font(for: .sidebarItem) == provider.sidebarItem)
            #expect(provider.font(for: .sidebarMeta) == provider.sidebarMeta)
            #expect(provider.font(for: .transcriptBody) == provider.transcriptBody)
            #expect(provider.font(for: .composerBody) == provider.composerBody)
            #expect(provider.font(for: .status) == provider.status)
            #expect(provider.font(for: .toolbar) == Font.system(size: 12))
            #expect(provider.font(for: .dangerousAction) == provider.dangerousAction)
        }
    }

    @Test func contentScaleEnvironmentDefaultsToOneAndAcceptsInjection() throws {
        #expect(EnvironmentValues().typographyContentScale == 1)
        let (center, dir) = try makeCenter()
        defer { try? FileManager.default.removeItem(at: dir) }
        center.uiBaseFontSize = 18
        var values = EnvironmentValues()
        values.typographyContentScale = TypographyTokenProvider(center: center).contentScale
        #expect(values.typographyContentScale == 18.0 / 14.0)
    }

    @Test func settingsCenterCanResetTypographyOnly() throws {
        let (center, dir) = try makeCenter()
        defer { try? FileManager.default.removeItem(at: dir) }
        center.uiBaseFontSize = 20

        center.resetTypographyToDefaults()

        #expect(center.uiBaseFontSize == 14)
        #expect(center.settingsStore.settings.typography.uiBaseFontSize == 14)
    }

    @Test func baseFontSizeContractKeepsKeyBoundsAndEnabledStateStable() {
        #expect(TypographySettings.settingsKey == "typography.uiBaseFontSize")
        #expect(TypographySettings.defaultBaseFontSize == 14)
        #expect(TypographySettings.uiBaseFontSizeRange == 12...20)
        #expect(TypographySettings.uiBaseFontSizeStep == 1)
        #expect(TypographySettings.disabledReason == nil)
    }

    @Test func visibleTypographyConsumersUseSharedSemanticRoles() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paths = [
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift",
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift",
            "src/MinisCanvasApp/Sources/MinisCanvasApp/GlobalComposerView.swift",
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ContextPanelView.swift",
            "src/MinisCanvasApp/Sources/MinisCanvasApp/TaskCenterObservationView.swift",
            "src/MinisCanvasApp/Sources/MinisCanvasApp/MCPManagerView.swift",
            "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift"
        ]

        for path in paths {
            let source = try String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8
            )
            #expect(
                source.contains("@Environment(\\.typographyTokens)")
                    || source.contains("typography?.")
                    || source.contains("typography.")
            )
        }
    }
}
