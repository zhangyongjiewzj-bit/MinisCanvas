import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class Handoff483Provider: LLMProvider, @unchecked Sendable {
    let name = "handoff483-local-only"
    var model = LLMModel(id: "handoff483", displayName: "Synthetic local probe", provider: "test")
    private let lock = NSLock()
    private var counts = [0, 0, 0]
    var calls: [Int] { lock.withLock { counts } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { counts[0] += 1 }
        return LLMResponse(text: "unexpected", stopReason: "end_turn", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        lock.withLock { counts[1] += 1 }
        return LLMResponse(text: "unexpected", stopReason: "end_turn", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        lock.withLock { counts[2] += 1 }
        return AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
private final class Handoff483Counters {
    var requests: [PendingCommandRequest] = []
    var settingsEntrySignals = 0
    var settingsPresented = false
    var modelPickerSignals = 0
    var terminals: [ComposerCommandAdjudicationCenter.Resolution] = []
    var acceptedResolutions: [Bool] = []
}

private struct Handoff483PersistedPending: Decodable {
    let id: UUID
    let commandID: String
    let args: [String: String]
    let requiresPolicyApproval: Bool
}

private struct Handoff483Envelope: Decodable {
    let pending: Handoff483PersistedPending?
    let receipt: ComposerCommandReceipt?
}

@Suite("N05 local model picker keeps the original single receipt without approval")
@MainActor
struct ComposerSettingsHandoffReceipt483Tests {
    private struct Harness {
        let chat: ChatStore
        let center: ComposerCommandAdjudicationCenter
        let registry: CommandRegistry
        let store: SessionStore
        let provider: Handoff483Provider
        let counters: Handoff483Counters
    }

    private func harness(root: URL, suffix: String, createSession: Bool) throws -> Harness {
        let store = SessionStore(directory: root)
        if createSession {
            _ = try store.createSession(id: UUID().uuidString, title: "Synthetic Settings handoff owner")
        }
        let requiredValue561_1 = UserDefaults(suiteName: "handoff483-\(suffix)-\(UUID().uuidString)")
        let defaults561: UserDefaults = try #require(requiredValue561_1)
        let chat = ChatStore(
            preferencesDefaults: defaults561,
            logManager: LogManager(directory: root.appendingPathComponent("logs-\(suffix)")))
        #expect(chat.attachPersistence(store,
            badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges-\(suffix)"))))
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        let center = ComposerCommandAdjudicationCenter()
        #expect(ProductionCommandRegistryWiring.bind(registry: registry, chat: chat, center: center))
        let provider = Handoff483Provider()
        let counters = Handoff483Counters()
        chat.streamingProviderOverride = provider
        chat.compactionProviderOverride = provider
        chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
        chat.configureComposerPolicy(ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "handoff483-policy",
            grantEpoch: "handoff483-epoch", leaseID: "handoff483-lease",
            expiresAt: Date().addingTimeInterval(600), revoked: false))
        chat.onComposerCommandPolicy = { [weak chat, weak center] request, snapshot in
            counters.requests.append(request)
            guard let chat, let center else { return .reject }
            return center.evaluate(request: request, snapshot: snapshot, facts: chat.composerPolicyFacts)
        }
        // The actual composition root's Settings entry is presentation state,
        // not automatic model configuration. Observe that signal without opening UI.
        center.openCanonicalSettings = {
            counters.settingsEntrySignals += 1
            counters.settingsPresented = true
        }
        let desktop = N05DesktopCommandConsumer(chat: chat,
            openSettings: { _ in
                counters.settingsEntrySignals += 1
                counters.settingsPresented = true
            },
            openModelPicker: { counters.modelPickerSignals += 1 },
            openContext: { Issue.record("Model command must not open context") },
            openDoctor: { Issue.record("Model command must not open diagnostics") },
            enterPlanMode: { _ in Issue.record("Model command must not enter plan mode"); return false },
            redactor: { ChatTranscriptRedactor(secretValues: []) })
        center.desktopCommandAction = { request, snapshot in
            try desktop.execute(request, snapshot: snapshot)
        }
        center.onPendingTerminalResolution = { [weak chat] resolution in
            counters.terminals.append(resolution)
            counters.acceptedResolutions.append(chat?.resolvePendingComposerCommand(
                requestID: resolution.id, disposition: .execute) ?? false)
        }
        return Harness(chat: chat, center: center, registry: registry, store: store,
                       provider: provider, counters: counters)
    }

    @Test(arguments: ["/model", "/模型"])
    func modelPickerConsumesTheSameIDOnlyOnceWithoutApprovalUserOrProvider(input: String) async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("handoff483-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let fixture = try harness(root: root, suffix: "initial", createSession: true)
        let chat = fixture.chat
        let owner = try #require(chat.activeSessionID)
        let before = chat.messages
        let persistedBefore = try #require(fixture.store.loadSession(id: owner.uuidString))
        #expect(chat.registeredComposerCommandRegistry === fixture.registry)
        #expect(fixture.center.commandRegistry === fixture.registry)
        #expect(fixture.registry.command(id: "model")?.requiresConfirmation == false)
        #expect(CommandRegistry.composerMetadata(for: "model")?.risk == .low)
        chat.draftText = input
        chat.submitComposer() // Actual public submission, no manufactured pending request.
        await Task.yield()
        let original = try #require(chat.lastComposerCommandReceipt)
        let request = try #require(fixture.counters.requests.first)
        let snapshot = try #require(chat.lastComposerSubmissionSnapshot)
        #expect(fixture.counters.requests.count == 1 && request.commandID == "model" && request.args.isEmpty)
        #expect(!request.requiresPolicyApproval && original.disposition == .execute)
        #expect(original.commandID == "model" && original.requestID == request.id)
        #expect(original.sessionID == owner.uuidString && original.turnID == snapshot.turnID)
        #expect(original.taskID == snapshot.taskID && original.attemptID == snapshot.attemptID)
        #expect(chat.pendingComposerCommand == nil && fixture.center.pendingAdjudication == nil)
        #expect(fixture.counters.settingsEntrySignals == 0 && fixture.counters.terminals.isEmpty)
        #expect(!fixture.counters.settingsPresented && fixture.counters.modelPickerSignals == 1)
        #expect(chat.messages == before && chat.draftText.isEmpty && fixture.provider.calls == [0, 0, 0])

        #expect(!fixture.center.approveCurrentAdjudication())
        #expect(fixture.center.lastResolution == nil)
        #expect(fixture.center.projection?.id == request.id && fixture.center.projection?.commandID == "model")
        #expect(fixture.counters.terminals.isEmpty && fixture.counters.acceptedResolutions.isEmpty)
        #expect(fixture.counters.modelPickerSignals == 1)
        #expect(fixture.counters.settingsEntrySignals == 0 && !fixture.counters.settingsPresented)
        #expect(chat.lastComposerCommandReceipt == original)
        #expect(chat.messages == before && fixture.provider.calls == [0, 0, 0])
        let stateURL = root.appendingPathComponent("chat-composer-command-state.json")
        let settledBytes = try Data(contentsOf: stateURL)
        let envelope = try JSONDecoder().decode(Handoff483Envelope.self, from: settledBytes)
        #expect(envelope.pending == nil && envelope.receipt == original)
        let persistedAfter = try #require(fixture.store.loadSession(id: owner.uuidString))
        #expect(persistedAfter.messages == persistedBefore.messages)

        #expect(!fixture.center.approveCurrentAdjudication())
        #expect(!chat.resolvePendingComposerCommand(requestID: request.id, disposition: .execute))
        chat.submitComposer() // Empty retry is not a second command or user turn.
        await Task.yield()
        #expect(fixture.counters.requests == [request])
        #expect(fixture.counters.terminals.isEmpty)
        #expect(fixture.counters.acceptedResolutions.isEmpty && fixture.counters.settingsEntrySignals == 0)
        #expect(fixture.counters.modelPickerSignals == 1)
        #expect(chat.lastComposerCommandReceipt == original && chat.messages == before)
        #expect(try Data(contentsOf: stateURL) == settledBytes)
        #expect(fixture.provider.calls == [0, 0, 0] && !chat.isStreaming)

        let restored = try harness(root: root, suffix: "restored", createSession: false)
        await Task.yield()
        #expect(restored.chat.activeSessionID == owner)
        #expect(restored.chat.lastComposerCommandReceipt == original && restored.chat.pendingComposerCommand == nil)
        #expect(restored.chat.messages == before && restored.provider.calls == [0, 0, 0])
        #expect(restored.counters.requests.isEmpty && restored.counters.terminals.isEmpty)
        #expect(restored.counters.settingsEntrySignals == 0 && !restored.counters.settingsPresented)
        #expect(restored.counters.modelPickerSignals == 0)
        #expect(restored.center.pendingAdjudication == nil && restored.center.projection == nil)
        // Owned fixtures are retained. No model settings, credentials or UI are changed.
    }
}
