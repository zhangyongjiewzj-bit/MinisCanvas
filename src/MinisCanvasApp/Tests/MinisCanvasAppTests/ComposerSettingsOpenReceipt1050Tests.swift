import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

private final class SettingsOpen1050Provider: LLMProvider, @unchecked Sendable {
    let name = "owned-command1050"
    var model = LLMModel(id: "owned-command1050", displayName: "Owned command control", provider: "test")
    private let lock = NSLock()
    private var counts = [0, 0, 0]
    var calls: [Int] { lock.withLock { counts } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { counts[0] += 1 }
        return LLMResponse(text: "unexpected ordinary Provider", stopReason: "end_turn", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        lock.withLock { counts[1] += 1 }
        return LLMResponse(text: "unexpected ordinary tool Provider", stopReason: "end_turn", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        lock.withLock { counts[2] += 1 }
        return AsyncThrowingStream { $0.finish() }
    }
}

private struct SettingsOpen1050Envelope: Decodable {
    let receipt: ComposerCommandReceipt?
    let pending: SettingsOpen1050Pending?
}
private struct SettingsOpen1050Pending: Decodable { let id: UUID }

@MainActor
private final class SettingsOpen1050CompletionJournal {
    var dispatches = 0
    var effects = 0
    var firstResult: Bool?
    var heldFirstCompletion: (@MainActor @Sendable (Bool) -> Void)?
}

@Suite("D-COMMAND-08 actual Composer settings.open receipt", .serialized)
@MainActor
struct ComposerSettingsOpenReceipt1050Tests {
    private struct Fixture {
        let bridge: BridgeStore
        let center: ComposerCommandAdjudicationCenter
        let sessions: SessionStore
        let provider: SettingsOpen1050Provider
    }

    private func makeFixture(root: URL, sessions: SessionStore? = nil) throws -> Fixture {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let store = sessions ?? SessionStore(directory: root.appendingPathComponent("sessions"))
        if sessions == nil {
            _ = try store.createSession(id: UUID().uuidString, title: "Owned command1050 canonical owner")
        }
        let defaults = try #require(UserDefaults(suiteName: "command1050-\(UUID().uuidString)"))
        let bridge = BridgeStore(shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults, logManager: LogManager(directory: root.appendingPathComponent("logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: store.directory), sessionStore: store,
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            canvasFeatureLane: .phase3NonCanvas)
        #expect(bridge.chat.attachPersistence(store))
        let center = ComposerCommandAdjudicationCenter()
        #expect(ProductionCommandRegistryWiring.bind(bridge: bridge, center: center))
        let provider = SettingsOpen1050Provider()
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.compactionProviderOverride = provider
        return Fixture(bridge: bridge, center: center, sessions: store, provider: provider)
    }

    private func awaitEffect(_ count: () -> Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while count() == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(count() == 1, "real AppCommandCatalog→DeepLink effect must execute exactly once")
    }

    @Test("Composer slash opens Settings exactly once with one durable receipt and no user/Provider turn")
    func actualComposerSettingsOpenHasOneReceiptAndPreservesResetConfirmation() async throws {
        // The actual test executable uses the canonical .xctest detection:
        // the registry's default KeychainStore therefore uses in-memory backing.
        try #require(KeychainStore.isTesting)
        let resolvedPaths = try FormalTestIsolationPaths.resolveCurrentProcess()
        let paths = try #require(resolvedPaths)
        let root = paths.rootDirectory.appendingPathComponent("command1050-\(UUID().uuidString)")

        // Non-Composer entry is an independent control, not a manufactured
        // slash callback. Its successful App action correctly has no receipt.
        let menu = try makeFixture(root: root.appendingPathComponent("menu"))
        var menuEffects: [String?] = []
        menu.bridge.deepLinkHandler.onOpenSettings = { menuEffects.append($0) }
        let menuBefore = menu.bridge.chat.messages
        let menuUpdatedAt = menu.bridge.chat.sessions.first { $0.id == menu.bridge.chat.activeSessionID }?.updatedAt
        menu.bridge.activateCommandRow(id: "settings.open")
        try await awaitEffect { menuEffects.count }
        #expect(menuEffects.count == 1 && menuEffects[0] == nil)
        #expect(menu.bridge.chat.lastComposerCommandReceipt == nil)
        #expect(menu.bridge.chat.messages.filter { $0.role == .user } == menuBefore.filter { $0.role == .user })
        #expect(menu.bridge.chat.messages == menuBefore)
        #expect(menu.bridge.chat.sessions.first { $0.id == menu.bridge.chat.activeSessionID }?.updatedAt == menuUpdatedAt)
        #expect(menu.provider.calls == [0, 0, 0])

        let fixture = try makeFixture(root: root.appendingPathComponent("composer"))
        let chat = fixture.bridge.chat
        let owner = try #require(chat.activeSessionID)
        var slashEffects: [String?] = []
        fixture.bridge.deepLinkHandler.onOpenSettings = { slashEffects.append($0) }
        let before = chat.messages
        let updatedAtBefore = chat.sessions.first { $0.id == owner }?.updatedAt
        let canonicalBefore = try #require(fixture.sessions.loadSession(id: owner.uuidString))
        let rows = ComposerSlashCommandMenu.entries(matching: "/settings.open",
                                                    registry: fixture.bridge.commandRegistry)
        let row = try #require(rows.first { $0.id == "settings.open" })
        #expect(row.shouldSendOnAccept && row.routedCommand?.id == "settings.open")
        #expect(!CommandRegistry.composerCommandIDs.contains("settings.open"))
        // Public ordinary Composer submission, using the real registered row
        // identity. Neither the test nor a wrapper manufactures a receipt.
        chat.draftText = "/" + row.completionCommand.id
        chat.submitComposer()
        try await awaitEffect { slashEffects.count }
        // The DeepLink effect can precede the registry's actual completion
        // during its actor hop; await the real terminal receipt independently.
        let receiptDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while chat.lastComposerCommandReceipt?.disposition != .execute,
              ContinuousClock.now < receiptDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = try #require(chat.lastComposerSubmissionSnapshot)
        let receipt = chat.lastComposerCommandReceipt
        #expect(slashEffects.count == 1 && slashEffects[0] == nil)
        #expect(receipt != nil, "successful Composer settings.open requires a structured receipt")
        #expect(receipt?.commandID == "settings.open" && receipt?.args == [:])
        #expect(receipt?.disposition == .execute)
        #expect(receipt?.sessionID == owner.uuidString && receipt?.turnID == snapshot.turnID)
        #expect(receipt?.taskID == snapshot.taskID && receipt?.attemptID == snapshot.attemptID)
        #expect(chat.pendingComposerCommand == nil && fixture.center.pendingAdjudication == nil)
        #expect(chat.composerCommandValidationFailure == nil && chat.draftText.isEmpty)
        #expect(chat.messages.filter { $0.role == .user } == before.filter { $0.role == .user })
        #expect(chat.messages == before)
        #expect(chat.sessions.first { $0.id == owner }?.updatedAt == updatedAtBefore)
        #expect(fixture.provider.calls == [0, 0, 0] && !chat.hasStreamingTasksForSafety)
        let settledMessages = chat.messages
        let canonicalAfter = try #require(fixture.sessions.loadSession(id: owner.uuidString))
        #expect(canonicalAfter.messages == canonicalBefore.messages)
        #expect(canonicalAfter.messages.isEmpty, "settings navigation must not create a transcript message")

        let stateURL = fixture.sessions.directory.appendingPathComponent("chat-composer-command-state.json")
        let hasState = FileManager.default.fileExists(atPath: stateURL.path)
        #expect(hasState, "the receipt must be on disk, not just an in-memory projection")
        var stateBytes: Data?
        if hasState {
            stateBytes = try Data(contentsOf: stateURL)
            let envelope = try JSONDecoder().decode(SettingsOpen1050Envelope.self, from: try #require(stateBytes))
            #expect(envelope.receipt == receipt && envelope.pending == nil)
        }

        // Empty retry is not another effect/receipt. settings.reset still has
        // no confirmation entry and must preserve the old successful receipt.
        chat.submitComposer()
        chat.draftText = "/settings.reset"
        chat.submitComposer()
        await Task.yield()
        #expect(chat.draftText == "/settings.reset")
        #expect(chat.composerCommandValidationFailure?.commandID == "settings.reset")
        #expect(chat.composerCommandValidationFailure?.message.contains("确认") == true)
        #expect(slashEffects.count == 1 && chat.lastComposerCommandReceipt == receipt)
        #expect(chat.messages == settledMessages && fixture.provider.calls == [0, 0, 0])
        if let stateBytes { #expect(try Data(contentsOf: stateURL) == stateBytes) }
        let reopened = try makeFixture(root: root.appendingPathComponent("reopened"),
            sessions: SessionStore(directory: fixture.sessions.directory))
        #expect(reopened.bridge.chat.activeSessionID == owner)
        #expect(reopened.bridge.chat.lastComposerCommandReceipt == receipt)
        #expect(reopened.bridge.chat.pendingComposerCommand == nil)
        #expect(reopened.bridge.chat.messages == before && reopened.provider.calls == [0, 0, 0])
        #expect(fixture.sessions.loadSession(id: owner.uuidString)?.messages == canonicalAfter.messages)
    }

    @Test("real old and duplicate App results cannot overwrite the next Composer command receipt")
    func realResultCompletionKeepsOriginalIdentityAndRejectsLateDuplicates() async throws {
        let resolvedPaths = try FormalTestIsolationPaths.resolveCurrentProcess()
        let paths = try #require(resolvedPaths)
        let root = paths.rootDirectory.appendingPathComponent("command1050-order-\(UUID().uuidString)")
        let fixture = try makeFixture(root: root)
        let chat = fixture.bridge.chat
        let aID = try #require(chat.activeSessionID)
        let originalDispatch = try #require(chat.onRegisteredNonComposerSlashCommand)
        let journal = SettingsOpen1050CompletionJournal()
        fixture.bridge.deepLinkHandler.onOpenSettings = { _ in journal.effects += 1 }
        // Transparently hold only the original registry's real result after
        // its actual effect. No command, effect or result is substituted.
        chat.onRegisteredNonComposerSlashCommand = { id, args, completion in
            journal.dispatches += 1
            let occurrence = journal.dispatches
            return originalDispatch(id, args) { succeeded in
                if occurrence == 1 {
                    journal.firstResult = succeeded
                    journal.heldFirstCompletion = completion
                } else {
                    completion(succeeded)
                    completion(false) // duplicate cannot reverse actual success
                }
            }
        }
        chat.draftText = "/settings.open"
        chat.submitComposer()
        let aSnapshot = try #require(chat.lastComposerSubmissionSnapshot)
        let aReceipt = try #require(chat.lastComposerCommandReceipt)
        #expect(aReceipt.disposition == .pending && aReceipt.sessionID == aID.uuidString)
        let firstDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while journal.firstResult == nil, ContinuousClock.now < firstDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let firstResult = try #require(journal.firstResult as Bool?)
        let held = try #require(journal.heldFirstCompletion)
        #expect(firstResult && journal.effects == 1 && journal.dispatches == 1)
        #expect(chat.lastComposerCommandReceipt == aReceipt)
        let bID = chat.applyNewSession(title: "Owned command1050 B")
        #expect(bID != aID)
        chat.draftText = "/settings.open"
        chat.submitComposer()
        let bSnapshot = try #require(chat.lastComposerSubmissionSnapshot)
        let secondDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while chat.lastComposerCommandReceipt?.disposition != .execute,
              ContinuousClock.now < secondDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let bReceipt = try #require(chat.lastComposerCommandReceipt)
        #expect(bReceipt.disposition == .execute && journal.effects == 2 && journal.dispatches == 2)
        #expect(bReceipt.requestID != aReceipt.requestID)
        #expect(bReceipt.sessionID == bID.uuidString && bReceipt.turnID == bSnapshot.turnID)
        #expect(bReceipt.taskID == bSnapshot.taskID && bReceipt.attemptID == bSnapshot.attemptID)
        #expect(bReceipt.taskID != aSnapshot.taskID && bReceipt.attemptID != aSnapshot.attemptID)
        let stateURL = fixture.sessions.directory.appendingPathComponent("chat-composer-command-state.json")
        let settledBytes = try Data(contentsOf: stateURL)
        held(firstResult)
        held(false)
        #expect(chat.lastComposerCommandReceipt == bReceipt)
        #expect(try Data(contentsOf: stateURL) == settledBytes)
        #expect(journal.effects == 2 && journal.dispatches == 2)
        #expect(chat.pendingComposerCommand == nil && fixture.center.pendingAdjudication == nil)
        #expect(chat.messages.filter { $0.role == .user }.isEmpty)
        #expect(fixture.provider.calls == [0, 0, 0] && !chat.hasStreamingTasksForSafety)
        #expect(fixture.sessions.loadSession(id: aID.uuidString)?.messages.isEmpty == true)
        #expect(fixture.sessions.loadSession(id: bID.uuidString)?.messages.isEmpty == true)
    }
}
