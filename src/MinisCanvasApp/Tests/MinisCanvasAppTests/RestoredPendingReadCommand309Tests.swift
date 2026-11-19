import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class Pending309ProviderProbe: LLMProvider, @unchecked Sendable {
    let name = "pending309-synthetic"
    var model = LLMModel(id: "pending309", displayName: "Synthetic", provider: "test")
    private(set) var calls = 0

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        calls += 1
        return LLMResponse(text: "unexpected provider invocation", stopReason: "end_turn", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        calls += 1
        return AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
private final class Pending309Counters {
    var policy = 0
    var terminals = 0
    var replays = 0
    var settings = 0
}

@Suite("D-COMMAND-02 restored pending survives read-only Composer commands")
@MainActor
struct RestoredPendingReadCommand309Tests {
    private struct Harness {
        let chat: ChatStore
        let center: ComposerCommandAdjudicationCenter
        let provider: Pending309ProviderProbe
        let counters: Pending309Counters
    }

    private func root() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-read309-\(UUID().uuidString)", isDirectory: true)
        let now = Date()
        try SessionStore(directory: directory).updateSession(ChatSession(
            id: UUID().uuidString, title: "Synthetic pending command",
            createdAt: now, updatedAt: now, messages: []
        ))
        return directory
    }

    private func harness(root: URL, suffix: String) throws -> Harness {
        let requiredValue561_1 = UserDefaults(
            suiteName: "pending309.\(root.lastPathComponent).\(suffix)"
        )
        let defaults561: UserDefaults = try #require(requiredValue561_1)
        let chat = ChatStore(
            preferencesDefaults: defaults561,
            logManager: LogManager(directory: root.appendingPathComponent("logs-\(suffix)"))
        )
        #expect(chat.attachPersistence(SessionStore(directory: root)))
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        let center = ComposerCommandAdjudicationCenter()
        #expect(ProductionCommandRegistryWiring.bind(registry: registry, chat: chat, center: center))
        let counters = Pending309Counters()
        let provider = Pending309ProviderProbe()
        chat.streamingProviderOverride = provider
        chat.compactionProviderOverride = provider
        let now = Date()
        center.clock = { now }
        chat.configureComposerPolicy(ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "pending309", grantEpoch: "pending309",
            leaseID: "pending309", expiresAt: now.addingTimeInterval(600), revoked: false
        ))
        chat.onComposerCommandPolicy = { [weak chat] request, snapshot in
            guard let chat else { return .reject }
            counters.policy += 1
            return center.evaluate(request: request, snapshot: snapshot, facts: chat.composerPolicyFacts)
        }
        center.replaySubmittedCommand = { _ in counters.replays += 1 }
        center.openCanonicalSettings = { counters.settings += 1 }
        // 用户自己提交的 /compact 在所有档位直接执行，不会再有待审状态；
        // 这里改用仍必须审批的 /add-dir 做“待审命令”（合成的目录授权，不触碰真实目录）。
        center.prepareAdditionalDirectory = { request, snapshot, facts in
            .init(request: request, snapshot: snapshot, facts: facts,
                physicalDirectory: URL(fileURLWithPath: request.args["path"] ?? "/synthetic/pending309"),
                directoryIdentity: "synthetic-device:inode", projectID: "synthetic-project",
                workingDirectory: "/synthetic/project", attachmentGeneration: 1)
        }
        center.applyApprovedAdditionalDirectory = { context in
            .init(requestID: context.request.id, sessionID: context.snapshot.sessionID,
                  path: context.physicalDirectory.path)
        }
        center.onPendingTerminalResolution = { [weak chat] resolution in
            counters.terminals += 1
            let disposition: ComposerCommandPolicyDecision
            switch resolution.outcome {
            case .approvedExecuted, .handedToCanonicalSettings: disposition = .execute
            default: disposition = .reject
            }
            _ = chat?.resolvePendingComposerCommand(requestID: resolution.id, disposition: disposition)
        }
        if let restored = chat.pendingComposerCommand {
            center.adoptRestoredPending(restored, sessionID: chat.activeSessionID?.uuidString ?? "")
        }
        return Harness(chat: chat, center: center, provider: provider, counters: counters)
    }

    private func seedPending(_ fixture: Harness) throws -> PendingCommandRequest {
        fixture.chat.draftText = "/add-dir /synthetic/pending309"
        fixture.chat.submitComposer()
        let pending = try #require(fixture.chat.pendingComposerCommand)
        #expect(pending.commandID == "add-dir")
        #expect(fixture.chat.lastComposerCommandReceipt?.disposition == .pending)
        #expect(fixture.center.pendingAdjudication?.id == pending.id)
        #expect(fixture.provider.calls == 0)
        return pending
    }

    @Test(arguments: ["/help", "/commands", "/status", "/tasks", "/boundary", "/provider"])
    func restoredPendingSurvivesActualSubmitAndSecondRestart(input: String) async throws {
        let directory = try root()
        let first = try harness(root: directory, suffix: "first")
        let pending = try seedPending(first)
        let restored = try harness(root: directory, suffix: "restored")
        let card = restored.center.pendingAdjudication
        let transcript = restored.chat.messages
        #expect(restored.chat.pendingComposerCommand == pending)
        #expect(restored.counters.policy == 0)

        restored.chat.draftText = input
        restored.chat.submitComposer()
        await Task.yield()
        let readReceipt = try #require(restored.chat.lastComposerCommandReceipt)
        #expect(readReceipt.commandID == String(input.dropFirst()))
        #expect(readReceipt.requestID != pending.id)
        #expect(readReceipt.disposition == .execute)
        #expect(restored.center.projection?.id == readReceipt.requestID)
        #expect(restored.chat.pendingComposerCommand == pending)
        #expect(restored.center.pendingAdjudication == card)
        #expect(restored.center.lastResolution == nil)
        #expect(restored.chat.messages == transcript)
        #expect(restored.chat.draftText.isEmpty)
        #expect(!restored.chat.isActiveSessionStreaming)
        #expect(restored.counters.policy == 1)
        #expect(restored.counters.terminals == 0)
        #expect(restored.counters.replays == 0)
        #expect(restored.counters.settings == 0)
        #expect(restored.provider.calls == 0)

        // Read back through the real persistence consumer, not a test copy of
        // the envelope. The latest read receipt and older pending coexist.
        let again = try harness(root: directory, suffix: "again")
        #expect(again.chat.pendingComposerCommand == pending)
        #expect(again.chat.lastComposerCommandReceipt == readReceipt)
        #expect(again.center.pendingAdjudication?.id == pending.id)
        #expect(again.counters.policy == 0)
        #expect(again.counters.terminals == 0)
        #expect(again.counters.replays == 0)
        #expect(again.counters.settings == 0)
        #expect(again.provider.calls == 0)
    }

    @Test(arguments: ["/help", "/status"])
    func readWithoutPendingStillConsumesOnlyItsOwnRequest(input: String) async throws {
        let fixture = try harness(root: root(), suffix: "no-pending")
        let transcript = fixture.chat.messages
        fixture.chat.draftText = input
        fixture.chat.submitComposer()
        await Task.yield()
        let receipt = try #require(fixture.chat.lastComposerCommandReceipt)
        #expect(receipt.disposition == .execute)
        #expect(fixture.chat.pendingComposerCommand == nil)
        #expect(fixture.center.pendingAdjudication == nil)
        #expect(fixture.chat.messages == transcript)
        #expect(fixture.provider.calls == 0)
        #expect(fixture.counters.policy == 1)
        #expect(fixture.counters.terminals == 0)
        fixture.chat.submitComposer()
        #expect(fixture.chat.lastComposerCommandReceipt == receipt)
        #expect(fixture.counters.policy == 1)
    }

    @Test func originalPendingRemainsResolvableOnlyByItsMatchingTerminal() throws {
        let directory = try root()
        let first = try harness(root: directory, suffix: "first")
        let pending = try seedPending(first)
        let restored = try harness(root: directory, suffix: "restored")
        restored.chat.draftText = "/help"
        restored.chat.submitComposer()
        let read = try #require(restored.chat.lastComposerCommandReceipt)
        #expect(!restored.chat.resolvePendingComposerCommand(requestID: read.requestID, disposition: .reject))
        #expect(restored.chat.pendingComposerCommand == pending)
        #expect(!restored.chat.resolvePendingComposerCommand(requestID: pending.id, disposition: .pending))
        #expect(restored.chat.pendingComposerCommand == pending)

        restored.center.denyCurrentAdjudication()
        #expect(restored.center.lastResolution?.id == pending.id)
        #expect(restored.center.lastResolution?.outcome == .deniedByUser)
        #expect(restored.center.pendingAdjudication == nil)
        #expect(restored.chat.pendingComposerCommand == nil)
        #expect(restored.counters.terminals == 1)
        #expect(restored.counters.replays == 0)
        #expect(restored.counters.settings == 0)
        #expect(restored.provider.calls == 0)
        let again = try harness(root: directory, suffix: "after-denial")
        #expect(again.chat.pendingComposerCommand == nil)
        #expect(again.center.pendingAdjudication == nil)
    }
}
