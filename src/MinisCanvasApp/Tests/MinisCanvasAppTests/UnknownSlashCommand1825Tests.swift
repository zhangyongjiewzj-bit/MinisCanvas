import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("COMMAND01 explicit unknown slash admission", .serialized)
@MainActor
struct UnknownSlashCommand1825Tests {
    private func chat(_ body: (ChatStore) throws -> Void) throws {
        let suite = "unknown-slash1825-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        let store = ChatStore(preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")))
        let registry = CommandRegistry(commands: [])
        registry.registerComposerCommands()
        #expect(store.installComposerCommandRegistry(registry))
        try body(store)
    }

    @Test(arguments: ["/notacommand", "/UNKNOWN1825", "/not-a-command", "/not_a_command", "/unknown.command1825"])
    func unknownBareWordNeverReachesOrdinarySubmit(input: String) throws {
        try chat { store in
            var ordinarySubmissions = 0
            var policyCalls = 0
            // This existing production interception seam is downstream of
            // appendUser and immediately before model dispatch. Consuming it
            // prevents network access even if this negative regression fails.
            store.onSendCommand = { _, _ in ordinarySubmissions += 1; return true }
            store.onComposerCommandPolicy = { _, _ in policyCalls += 1; return .pending }
            let before = store.messages
            store.draftText = input
            store.submitComposer()
            let error = try #require(store.composerCommandValidationFailure)
            #expect(error.commandID == String(input.dropFirst()))
            #expect(error.sessionID == store.activeSessionID)
            #expect(error.message == CommandExecutionError.unknownCommand(error.commandID).errorDescription)
            #expect(store.messages == before)
            #expect(store.draftText == input)
            #expect(store.pendingComposerCommand == nil)
            #expect(store.lastComposerCommandReceipt == nil)
            #expect(ordinarySubmissions == 0 && policyCalls == 0)
            #expect(!store.isStreaming && !store.isActiveSessionStreaming)
        }
    }

    @Test(arguments: ["please discuss /notacommand", "/notacommand is quoted prose", "/usr/local/bin", "/", "/notacommand?", "https://example.invalid/notacommand", "```\n/notacommand\n```"])
    func ordinarySlashProseStillReachesExistingMessageBoundary(input: String) throws {
        try chat { store in
            var ordinarySubmissions = 0
            store.onSendCommand = { _, _ in ordinarySubmissions += 1; return true }
            store.draftText = input
            store.submitComposer()
            #expect(store.composerCommandValidationFailure == nil)
            #expect(ordinarySubmissions == 1)
            #expect(store.messages.contains { $0.role == .user && $0.content == input })
            #expect(store.pendingComposerCommand == nil)
            #expect(!store.isStreaming)
        }
    }

    @Test(arguments: CommandRegistry.composerCommandIDs.sorted())
    func everyRegisteredComposerWordRetainsOriginalValidationAndPolicyRoute(word: String) throws {
        try chat { store in
            let registry = store.registeredComposerCommandRegistry
            let expectedIDs: Set<String> = ["help", "commands", "boundary", "boundary.set", "add-dir", "status", "copy", "tasks",
                "stop", "compact", "retry", "canvas.run", "canvas.cancel", "canvas.minimap", "provider",
                "provider.use", "model", "workflow", "approve", "reject", "memory", "memory.propose",
                "skills", "permissions", "mcp", "context", "clear", "rewind", "undo", "diff", "doctor", "usage", "export",
                "rename", "resume", "plan", "shortcuts"]
            #expect(Set(registry.allCommands().map(\.id)) == expectedIDs)
            #expect(CommandRegistry.composerCommandIDs == expectedIDs)
            let command = try #require(registry.command(id: word))
            var ordinarySubmissions = 0
            store.onSendCommand = { _, _ in ordinarySubmissions += 1; return true }
            store.onComposerCommandPolicy = { _, _ in .pending }
            let args = command.argumentSpecs.filter(\.required).map { spec in
                let value = spec.choices?.first ?? "synthetic1825"
                return "\(spec.name)=\"\(value)\""
            }.joined(separator: " ")
            let input = "/\(command.id)" + (args.isEmpty ? "" : " " + args)
            #expect(CommandParser().parse(input, registry: registry).command?.id == command.id)
            let before = store.messages
            store.draftText = input
            store.submitComposer()
            #expect(store.messages == before && ordinarySubmissions == 0)
            if let failure = store.composerCommandValidationFailure {
                #expect(failure.commandID == command.id)
                #expect(!failure.message.hasPrefix("未知命令"))
            } else {
                let receipt = try #require(store.lastComposerCommandReceipt)
                #expect(receipt.commandID == command.id && receipt.disposition == .pending)
                #expect(store.pendingComposerCommand?.id == receipt.requestID)
            }
        }
    }

    @Test func unknownInputPreservesAnEarlierApprovalRequest() throws {
        try chat { store in
            store.onComposerCommandPolicy = { _, _ in .pending }
            store.draftText = "/provider.use provider_model=synthetic1825"
            store.submitComposer()
            let pending = try #require(store.pendingComposerCommand)
            let receipt = try #require(store.lastComposerCommandReceipt)
            #expect(pending.requiresPolicyApproval)
            let before = store.messages
            store.draftText = "/notacommand"
            store.submitComposer()
            #expect(store.pendingComposerCommand == pending)
            #expect(store.lastComposerCommandReceipt == receipt)
            #expect(store.composerCommandValidationFailure?.commandID == "notacommand")
            #expect(store.messages == before && store.draftText == "/notacommand")
        }
    }
}
