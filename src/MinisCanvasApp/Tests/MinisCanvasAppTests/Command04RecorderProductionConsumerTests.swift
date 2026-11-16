import AppKit
import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-COMMAND-04 真实快捷键录制消费")
@MainActor
struct Command04RecorderProductionConsumerTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "command04-recorder-\(UUID().uuidString)")!
    }

    private func escape(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: 53
        ))
    }

    // Calls the exact handler installed by beginRecording without installing
    // a global event monitor, creating a window, or starting NSApplication.
    @Test(arguments: [NSEvent.ModifierFlags.command, .control, .option, .shift])
    func modifiedEscapePersistsAndUpdatesActualRegistryBadge(_ flags: NSEvent.ModifierFlags) throws {
        let preferences = defaults()
        let store = ShortcutStore(defaults: preferences)
        let recorder = ShortcutRecorderModel(store: store)
        recorder.recordingAction = .newSession
        recorder.handle(try escape(flags))
        let expected = ShortcutBinding(key: "escape", modifiers: ShortcutModifiers(
            command: flags.contains(.command), control: flags.contains(.control),
            option: flags.contains(.option), shift: flags.contains(.shift)
        ))
        #expect(recorder.recordingAction == nil)
        #expect(recorder.conflictError == nil)
        #expect(store.binding(for: .newSession) == expected)
        let reopened = ShortcutStore(defaults: preferences)
        #expect(reopened.binding(for: .newSession) == expected)
        let bridge = BridgeStore(shortcutStore: reopened)
        #expect(bridge.commandRegistry.command(id: "session.new") != nil)
        #expect(bridge.paletteDisplay["session.new"]?.shortcut == expected.displayString)
        #expect(reopened.setBinding(ShortcutBinding(key: "", modifiers: .none), for: .newSession) == nil)
        #expect(bridge.paletteDisplay["session.new"]?.shortcut == "无")
        #expect(ShortcutStore(defaults: preferences).binding(for: .newSession).isEmpty)
        #expect(reopened.reset(for: .newSession) == nil)
        #expect(bridge.paletteDisplay["session.new"]?.shortcut == "⌘N")
    }

    @Test func plainEscapeCancelsWithoutChangingExistingBinding() throws {
        let store = ShortcutStore(defaults: defaults())
        let existing = ShortcutBinding(key: "g", modifiers: ShortcutModifiers.command)
        #expect(store.setBinding(existing, for: .newSession) == nil)
        let recorder = ShortcutRecorderModel(store: store)
        recorder.recordingAction = .newSession
        recorder.handle(try escape([.capsLock]))
        #expect(recorder.recordingAction == nil)
        #expect(recorder.conflictError == nil)
        #expect(store.binding(for: .newSession) == existing)
    }

    @Test func modifiedEscapeConflictPreservesBothProductionBindings() throws {
        let preferences = defaults()
        let store = ShortcutStore(defaults: preferences)
        let occupied = ShortcutBinding(key: "escape", modifiers: ShortcutModifiers.command)
        #expect(store.setBinding(occupied, for: .openSettings) == nil)
        let recorder = ShortcutRecorderModel(store: store)
        recorder.recordingAction = .newSession
        recorder.handle(try escape(.command))
        #expect(recorder.recordingAction == nil)
        #expect(recorder.conflictError == .action(.openSettings))
        let reopened = ShortcutStore(defaults: preferences)
        #expect(reopened.binding(for: .openSettings) == occupied)
        #expect(reopened.binding(for: .newSession) == ShortcutAction.newSession.defaultBinding)
    }
}
