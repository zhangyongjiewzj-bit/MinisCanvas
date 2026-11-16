import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-APP-09 Chat three-column menu intent", .serialized)
@MainActor
struct App09ThreeColumnMenu2937ConsumerTests {
    @Test("registered menu action emits a fresh expand intent even when already split")
    func alreadySplitStillRequestsThreeColumns() async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("app09-menu-2937-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "app09-menu-2937-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            canvasFactory: { _ in preconditionFailure("Canvas is disabled in this owned fixture") },
            canvasRuntimeState: .disabled,
            canvasFeatureLane: .phase3NonCanvas
        )
        bridge.layoutMode = .split
        let row = try #require(AppCommandMenuBuilder.command(
            id: "ui.layout.split", registry: bridge.commandRegistry,
            display: bridge.paletteDisplay
        ))
        #expect(row.isEnabled)
        #expect(row.title == "布局：聊天三栏")
        let messagesBefore = bridge.chat.messages

        bridge.activateCommandRow(id: row.id)
        for _ in 0..<100 {
            if bridge.chatThreeColumnCommandCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(bridge.layoutMode == .split)
        #expect(bridge.chatThreeColumnCommandCount == 1)
        #expect(bridge.chat.messages == messagesBefore)

        // A second menu selection remains an explicit request, not a no-op.
        bridge.activateCommandRow(id: row.id)
        for _ in 0..<100 {
            if bridge.chatThreeColumnCommandCount == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(bridge.chatThreeColumnCommandCount == 2)
        #expect(bridge.chat.messages == messagesBefore)

        bridge.activateCommandRow(id: "ui.layout.chat")
        for _ in 0..<100 {
            if bridge.layoutMode == .chat { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(bridge.layoutMode == .chat)
        #expect(bridge.chatThreeColumnCommandCount == 2)
    }
}
