import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-COMMAND-02 ChatStore registry identity")
@MainActor
struct P3AcceptanceM02_CommandRegistryWiringTests {
    @Test("production installation is one-time and uses the same registry for dispatch")
    func installationPreservesIdentityAndRejectsReplacement() {
        let suite = "M02-command-registry-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        let chat = ChatStore(
            preferencesDefaults: defaults,
            logManager: LogManager(directory: logDirectory)
        )
        let assembled = CommandRegistry()
        assembled.registerComposerCommands()
        let replacement = CommandRegistry()
        replacement.registerComposerCommands()

        #expect(chat.installComposerCommandRegistry(assembled))
        #expect(chat.registeredComposerCommandRegistry === assembled)
        #expect(chat.installComposerCommandRegistry(assembled))
        #expect(!chat.installComposerCommandRegistry(replacement))
        #expect(chat.registeredComposerCommandRegistry === assembled)

        chat.draftText = "/help"
        chat.submitComposer()
        #expect(chat.registeredComposerCommandRegistry === assembled)
        #expect(!chat.installComposerCommandRegistry(replacement))
    }

    @Test("an isolated fixture keeps its original registry after a send attempt")
    func lateProductionInstallDoesNotReplaceFixtureRegistry() {
        let suite = "M02-command-registry-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        let chat = ChatStore(
            preferencesDefaults: defaults,
            logManager: LogManager(directory: logDirectory)
        )
        let original = chat.registeredComposerCommandRegistry
        chat.submitComposer()
        #expect(!chat.installComposerCommandRegistry(CommandRegistry()))
        #expect(chat.registeredComposerCommandRegistry === original)
    }
}
