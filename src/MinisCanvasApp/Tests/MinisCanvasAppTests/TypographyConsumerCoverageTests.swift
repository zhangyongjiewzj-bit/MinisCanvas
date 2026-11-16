import Foundation
import Testing
import SwiftUI
import MinisCore
@testable import MinisCanvasApp

@Suite("UX-01 shared typography consumer coverage")
@MainActor
struct TypographyConsumerCoverageTests {
    private func source(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @Test("All supported base sizes derive the semantic token family")
    func semanticTokensTrackSettingsFactSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UX01-Consumer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 20)
        )
        let provider = TypographyTokenProvider(center: center)

        for size in [12, 14, 16, 18, 20] {
            center.uiBaseFontSize = size
            #expect(provider.bodySize == CGFloat(size))
            #expect(provider.headlineSize == CGFloat(size + 2))
            #expect(provider.monospacedSize == CGFloat(size))
            #expect(provider.metricSize == CGFloat(size + 2))
            #expect(provider.captionSize >= 11)
            #expect(provider.caption2Size >= 10)
            #expect(provider.captionSize < provider.bodySize)
            #expect(provider.caption2Size < provider.captionSize)
        }
    }

    @Test("Production surfaces consume the shared typography environment")
    func productionConsumersHaveExplicitTypographyAnchors() throws {
        let paths = [
            "src/MinisCanvasApp/Sources/MinisCanvasApp/MinisCanvasApp.swift",
            "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift",
            "src/MinisCanvasApp/Sources/MinisCanvasApp/TaskCenterObservationView.swift",
            "src/MinisCanvasApp/Sources/MinisCanvasApp/MCPManagerView.swift",
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift"
        ]
        for path in paths {
            let contents = try source(path)
            #expect(
                contents.contains("TypographyTokenProvider")
                    || contents.contains("typographyTokens")
            )
            #expect(contents.contains(".font("))
        }
    }
}
