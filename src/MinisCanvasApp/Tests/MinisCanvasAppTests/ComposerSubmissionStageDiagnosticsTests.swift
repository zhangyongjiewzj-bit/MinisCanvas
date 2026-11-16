import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

private final class NoNetworkProvider775Engine: ChatAgentEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var observed: [(String, String)] = []
    private var observedCompactions: [(String, String)] = []
    var received: [(String, String)] { lock.withLock { observed } }
    var compactions: [(String, String)] { lock.withLock { observedCompactions } }
    var isAvailable: Bool { true }

    func streamReply(
        provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        lock.withLock { observed.append((provider.name, provider.model.id)) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.done(stopReason: .endTurn))
            continuation.finish()
        }
    }

    func streamReply(
        provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, maxTokens: Int,
        conversationID: String?, authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?, turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot,
        executionIdentity: AgentExecutionIdentity
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        guard composerSnapshot.sessionID == executionIdentity.turn.sessionID,
              composerSnapshot.turnID == executionIdentity.turn.turnID else {
            throw ChatTurnRuntimeSnapshotError.identityMismatch
        }
        return try await streamReply(
            provider: provider, history: history,
            systemPrompt: systemPrompt, maxTokens: maxTokens
        )
    }

    func streamReply(
        provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, maxTokens: Int,
        conversationID: String?, authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?, turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot,
        executionIdentity: AgentExecutionIdentity,
        turnRuntimeSnapshot: ChatTurnRuntimeSnapshot
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        guard composerSnapshot.sessionID == executionIdentity.turn.sessionID,
              composerSnapshot.turnID == executionIdentity.turn.turnID,
              turnRuntimeSnapshot.turn == executionIdentity.turn else {
            throw ChatTurnRuntimeSnapshotError.identityMismatch
        }
        return try await streamReply(
            provider: provider, history: history,
            systemPrompt: systemPrompt, maxTokens: maxTokens
        )
    }

    func interrupt() {}

    func compactContext(
        provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, keepRecent: Int
    ) async -> CompactionResult {
        lock.withLock { observedCompactions.append((provider.name, provider.model.id)) }
        return CompactionResult(messages: [], summary: nil, compactedCount: 0)
    }
}

actor HeldSubmissionDiagnosticPreflight {
    private var pending: CheckedContinuation<Bool, Never>?
    private var released = false

    func read() async -> Bool {
        if released { return true }
        return await withCheckedContinuation { continuation in
            pending = continuation
        }
    }

    func isPending() -> Bool { pending != nil }

    func finish() {
        guard !released else { return }
        released = true
        pending?.resume(returning: true)
        pending = nil
    }
}

@Suite("Composer submission stage diagnostics", .serialized)
@MainActor
struct ComposerSubmissionStageDiagnosticsTests {
    private let draftSentinel = "SYNTHETIC_SECRET_261_SYNTHETIC_KEY_261"
    private let pathSentinel = "/synthetic/SECRET_PATH_261.txt"

    private func makeChat() -> (ChatStore, LogManager) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-stage-\(UUID().uuidString)", isDirectory: true)
        let logger = LogManager(directory: directory, ringCapacity: 30)
        logger.isFileLoggingEnabled = false
        let defaults = UserDefaults(suiteName: "composer-stage-\(UUID().uuidString)")!
        let chat = ChatStore(preferencesDefaults: defaults, logManager: logger)
        return (chat, logger)
    }

    private func stageMessages(_ logger: LogManager) -> [String] {
        logger.recentLogs().filter { $0.category == "ComposerSubmission" }
            .reversed().map(\.message)
    }

    private func protectedSessionField(_ owner: UUID?) -> String {
        // The production LogManager masks assignments named sessionID.
        // Compare the protected identity, never require a raw session UUID in logs.
        "sessionID=\(EnvVarRedactor.redact(owner?.uuidString ?? "none"))"
    }

    private func assertNoPayload(_ messages: [String]) {
        for message in messages {
            let fields = message.split(separator: " ")
            #expect(fields.count == 4)
            #expect(fields.map { String($0.split(separator: "=", maxSplits: 1).first ?? "") } == [
                "stage", "reason", "sessionID", "messageID"
            ])
            #expect(!message.contains(draftSentinel))
            #expect(!message.contains(pathSentinel))
            #expect(!message.contains("SECRET_PATH_261"))
            #expect(!message.contains("SYNTHETIC_KEY_261"))
        }
    }

    @Test("default-off path preserves draft and emits no stage entries")
    func disabledEmitsNothing() {
        let (chat, logger) = makeChat()
        #expect(chat.composerSubmissionDiagnosticsEnabled == false)
        chat.draftText = draftSentinel
        chat.effectiveSettingsSnapshotSource = { nil }

        chat.recordComposerSendInvocation(canSend: true)
        chat.submitComposer()

        #expect(stageMessages(logger).isEmpty)
        #expect(chat.draftText == draftSentinel)
        #expect(chat.messages.allSatisfy { $0.role != .user })
    }

    @Test("opt-in logs the exact settings rejection before consuming the draft")
    func invalidSettingsHasTypedReason() {
        let (chat, logger) = makeChat()
        chat.composerSubmissionDiagnosticsEnabled = true
        chat.draftText = draftSentinel
        chat.effectiveSettingsSnapshotSource = { nil }
        let owner = chat.activeSessionID

        chat.recordComposerSendInvocation(canSend: true)
        chat.submitComposer()

        let entries = stageMessages(logger)
        #expect(entries.count == 3)
        #expect(entries[0].contains("stage=uiInvoked reason=none"))
        #expect(entries[1].contains("stage=submitEntered reason=none"))
        #expect(entries[2].contains("stage=submitRejected reason=effectiveSettingsUnavailable"))
        #expect(entries.allSatisfy { $0.contains(protectedSessionField(owner)) })
        if let owner {
            #expect(entries.allSatisfy { !$0.contains(owner.uuidString) })
        }
        #expect(chat.draftText == draftSentinel)
        #expect(chat.messages.allSatisfy { $0.role != .user })
        assertNoPayload(entries)
    }

    @Test("opt-in records the committed message identity without draft or attachment data")
    func appendedMessageIsRedacted() throws {
        let (chat, logger) = makeChat()
        chat.composerSubmissionDiagnosticsEnabled = true
        chat.streamingProviderOverride = MockProvider.shared
        let attachment = ChatAttachment(
            kind: .text, fileName: "SECRET_PATH_261.txt", fileType: .text,
            mimeType: "text/plain", size: 5, data: Data("hello".utf8),
            fileURL: pathSentinel
        )
        chat.addComposerDraftAttachment(attachment)
        chat.draftText = draftSentinel
        let owner = try #require(chat.activeSessionID)

        chat.recordComposerSendInvocation(canSend: true)
        chat.submitComposer()

        let sent = try #require(chat.messages.last(where: { $0.role == .user }))
        let entries = stageMessages(logger)
        #expect(entries.contains { $0.contains("stage=userMessageAppended reason=none")
            && $0.contains(protectedSessionField(owner))
            && $0.contains("messageID=\(sent.id.uuidString)") })
        #expect(entries.allSatisfy { !$0.contains(owner.uuidString) })
        #expect(chat.pendingAttachments.isEmpty)
        #expect(chat.draftText.isEmpty)
        assertNoPayload(entries)
    }

    @Test("committed credential turn is visible, deduplicated, and cancellable without engine execution")
    func pendingCredentialSendCanBeCancelled() async throws {
        let (chat, logger) = makeChat()
        chat.composerSubmissionDiagnosticsEnabled = true
        let engine = NoNetworkProvider775Engine()
        chat.agentEngine = engine
        let record = EnvVarEntry(
            name: "SYNTHETIC_PROVIDER_274", value: "", isSecret: true,
            valueInKeychain: true, baseURL: "https://example.invalid",
            modelNames: ["synthetic-model"], protocolType: .openaiCompatible
        )
        chat.selectedCustomProvider = record
        chat.providerRecordsSource = { [record] }
        chat.schedulerCredentialVersionSource = { _ in "synthetic-revision" }
        let held = HeldSubmissionDiagnosticPreflight()
        var reads = 0
        chat.providerCredentialPreflightSource = { _, _, _ in
            reads += 1
            return await held.read()
        }
        chat.draftText = draftSentinel
        chat.submitComposer()
        #expect(chat.isComposerCredentialPreflightPending)
        let startedBy = ContinuousClock.now + .seconds(2)
        while !(await held.isPending()) && ContinuousClock.now < startedBy {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let started = await held.isPending()
        guard started else {
            await held.finish()
            Issue.record("credential fixture did not start within its deadline")
            return
        }
        chat.submitComposer()
        #expect(stageMessages(logger).contains { $0.contains("stage=submitRejected reason=uiNotReady") })
        #expect(reads == 1)
        #expect(chat.draftText.isEmpty)
        #expect(chat.messages.filter { $0.role == .user }.count == 1)

        chat.cancelComposerCredentialPreflight()
        #expect(!chat.isComposerCredentialPreflightPending)
        await held.finish()
        let settledBy = ContinuousClock.now + .seconds(2)
        while !stageMessages(logger).contains(where: {
            $0.contains("reason=credentialPreflightSuperseded")
        }) && ContinuousClock.now < settledBy {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let entries = stageMessages(logger)
        #expect(entries.contains { $0.contains("reason=credentialPreflightSuperseded") })
        #expect(entries.contains { $0.contains("stage=userMessageAppended") })
        #expect(engine.received.isEmpty)
        #expect(chat.messages.last?.isStreaming == false)
        #expect(!chat.isComposerCredentialPreflightPending)
        #expect(chat.draftText.isEmpty)
        #expect(chat.messages.filter { $0.role == .user }.count == 1)
        #expect(reads == 1)
        assertNoPayload(entries)
    }

    @Test("Responses preparation commits one turn and cancellation prevents engine execution")
    func responsesPreparationCancellationKeepsDraft() async throws {
        let (chat, logger) = makeChat()
        chat.composerSubmissionDiagnosticsEnabled = true
        let engine = NoNetworkProvider775Engine()
        chat.agentEngine = engine
        let record = EnvVarEntry(
            name: "SYNTHETIC_RESPONSES_775", value: "owned-fixture-key",
            isSecret: true, valueInKeychain: false,
            baseURL: "https://example.invalid",
            modelNames: ["synthetic-model"], protocolType: .openaiResponses
        )
        chat.selectedCustomProvider = record
        let held = HeldSubmissionDiagnosticPreflight()
        chat.providerConstructionPauseForTests = { _ = await held.read() }
        chat.draftText = draftSentinel

        chat.submitComposer()
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await held.isPending()) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard await held.isPending() else {
            await held.finish()
            Issue.record("Responses construction worker did not start")
            return
        }
        #expect(chat.isComposerProviderPreparationPending)
        #expect(chat.isComposerCredentialPreflightPending)
        #expect(chat.draftText.isEmpty)
        #expect(chat.messages.filter { $0.role == .user }.count == 1)
        chat.submitComposer()
        #expect(stageMessages(logger).contains {
            $0.contains("stage=submitRejected reason=uiNotReady")
        })

        chat.cancelComposerCredentialPreflight()
        await held.finish()
        #expect(!chat.isComposerProviderPreparationPending)
        #expect(!chat.isComposerCredentialPreflightPending)
        #expect(chat.draftText.isEmpty)
        #expect(chat.messages.filter { $0.role == .user }.count == 1)
        #expect(engine.received.isEmpty)
        #expect(chat.messages.last?.isStreaming == false)
        assertNoPayload(stageMessages(logger))
    }

    @Test("Responses primary constructs from the frozen selection and reaches a no-network engine")
    func responsesPrimaryUsesFrozenProviderWithoutNetwork() async throws {
        let checkpointDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("responses-775-owned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: checkpointDirectory, withIntermediateDirectories: true
        )
        OpenAIResponsesProvider.attemptCheckpointDirectoryOverride = checkpointDirectory
        defer {
            OpenAIResponsesProvider.attemptCheckpointDirectoryOverride = nil
            try? FileManager.default.removeItem(at: checkpointDirectory)
        }
        let (chat, _) = makeChat()
        let engine = NoNetworkProvider775Engine()
        chat.agentEngine = engine
        let record = EnvVarEntry(
            name: "SYNTHETIC_RESPONSES_PRIMARY_775", value: "owned-fixture-key",
            isSecret: true, valueInKeychain: false,
            baseURL: "https://example.invalid",
            modelNames: ["synthetic-model"], protocolType: .openaiResponses
        )
        chat.selectedCustomProvider = record
        chat.selectedModelID = "synthetic-model"
        chat.draftText = "owned Responses turn"
        chat.submitComposer()
        let sessionID = try #require(chat.activeSessionID)
        let execution = try #require(chat.activeExecutionIdentity(for: sessionID))
        let deadline = ContinuousClock.now + .seconds(2)
        while (engine.received.isEmpty || chat.terminalReceipt(for: execution) == nil)
            && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(engine.received.count == 1)
        #expect(engine.received.first?.0 == record.name)
        #expect(engine.received.first?.1 == "synthetic-model")
        #expect(chat.messages.filter { $0.role == .user }.count == 1)
        #expect(chat.draftText.isEmpty)
        #expect(chat.terminalReceipt(for: execution)?.outcome == .succeeded)
        #expect(!chat.isComposerProviderPreparationPending)
    }

    @Test("compatible Provider preparation leaves the Composer responsive and rejects a changed model")
    func compatibleProviderPreparationRejectsChangedModel() async throws {
        let (chat, logger) = makeChat()
        chat.composerSubmissionDiagnosticsEnabled = true
        let engine = NoNetworkProvider775Engine()
        chat.agentEngine = engine
        let record = EnvVarEntry(
            name: "SYNTHETIC_COMPATIBLE_806", value: "owned-fixture-key",
            isSecret: true, valueInKeychain: false,
            baseURL: "https://example.invalid",
            modelNames: ["model-a", "model-b"], protocolType: .openaiCompatible
        )
        chat.selectedCustomProvider = record
        chat.selectedModelID = "model-a"
        chat.draftText = "owned compatible turn"
        let held = HeldSubmissionDiagnosticPreflight()
        chat.providerConstructionPauseForTests = { _ = await held.read() }

        chat.submitComposer()
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await held.isPending()) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard await held.isPending() else {
            await held.finish()
            Issue.record("compatible Provider worker did not start")
            return
        }
        #expect(chat.isComposerProviderPreparationPending)
        #expect(chat.draftText.isEmpty)
        chat.selectedModelID = "model-b"
        await held.finish()
        while chat.isComposerProviderPreparationPending && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(!chat.isComposerProviderPreparationPending)
        #expect(chat.draftText.isEmpty)
        #expect(chat.messages.filter { $0.role == .user }.count == 1)
        #expect(chat.messages.last?.isStreaming == false)
        #expect(engine.received.isEmpty)
        #expect(stageMessages(logger).contains {
            $0.contains("stage=providerPreparationRejected reason=providerPreparationFenceChanged")
        })
    }

    @Test func committedPreparationTimesOutWithoutReplayingTheTurn() async throws {
        try await assertCommittedPreparationTimeout(holdPromptAfterConstruction: false)
    }

    @Test func promptPreparationKeepsTheOriginalProviderDeadline() async throws {
        try await assertCommittedPreparationTimeout(holdPromptAfterConstruction: true)
    }

    private func assertCommittedPreparationTimeout(holdPromptAfterConstruction: Bool) async throws {
        let (chat, _) = makeChat()
        let engine = NoNetworkProvider775Engine()
        chat.agentEngine = engine
        let sessionID = try #require(chat.activeSessionID)
        chat.selectedCustomProvider = EnvVarEntry(
            name: "SYNTHETIC_COMMITTED_DEADLINE", value: "owned-fixture-key",
            isSecret: true, valueInKeychain: false,
            baseURL: "https://example.invalid",
            modelNames: ["synthetic-model"], protocolType: .openaiCompatible
        )
        chat.selectedModelID = "synthetic-model"
        let submitted = "owned committed turn before timeout"
        let nextDraft = "owned draft for the next turn"
        chat.draftText = submitted
        let held = HeldSubmissionDiagnosticPreflight()
        let heldPrompt = HeldSubmissionDiagnosticPreflight()
        chat.providerConstructionPauseForTests = { _ = await held.read() }
        if holdPromptAfterConstruction {
            chat.turnPromptPreprocessPauseForTests = { _ = await heldPrompt.read() }
        }
        defer {
            chat.stopStreamingPreservingQueue()
            Task {
                await held.finish()
                await heldPrompt.finish()
            }
        }

        let startedAt = ContinuousClock.now
        chat.submitComposer()
        let entryLimit = startedAt + .seconds(3)
        while !(await held.isPending()) && ContinuousClock.now < entryLimit {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await held.isPending())
        try #require(chat.isComposerProviderPreparationPending)
        let construction = try #require(chat.turnTaskForTests(sessionID: sessionID))
        let original = try #require(chat.messages.first { $0.role == .user && $0.content == submitted })
        let assistant = try #require(chat.messages.last { $0.role == .assistant && $0.isStreaming })
        #expect(engine.received.isEmpty)
        chat.draftText = nextDraft
        let stalledPhase: HeldSubmissionDiagnosticPreflight
        let preparation: Task<Void, Never>
        if holdPromptAfterConstruction {
            // Make a reset at construction-to-prompt handoff distinguishable
            // from the one-second tolerance around the original deadline.
            try await ContinuousClock().sleep(until: startedAt + .seconds(4))
            await held.finish()
            await construction.value
            let promptEntryLimit = ContinuousClock.now + .seconds(3)
            while !(await heldPrompt.isPending()) && ContinuousClock.now < promptEntryLimit {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(await heldPrompt.isPending())
            #expect(chat.isComposerProviderPreparationPending)
            stalledPhase = heldPrompt
            preparation = try #require(chat.turnTaskForTests(sessionID: sessionID))
        } else {
            stalledPhase = held
            preparation = construction
        }

        // The proposed cap is 30 seconds, with one second to present the
        // terminal state on the MainActor under the test runner.
        let observationLimit = startedAt + .seconds(31)
        while chat.isComposerProviderPreparationPending && ContinuousClock.now < observationLimit {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await stalledPhase.isPending())
        #expect(!chat.isComposerProviderPreparationPending)
        let settled = try #require(chat.messages.first { $0.id == assistant.id })
        #expect(!settled.isStreaming)
        #expect(settled.content.contains("超时") && settled.content.contains("重试"))
        #expect(chat.messages.filter { $0.role == .user }.map(\.id) == [original.id])
        #expect(chat.draftText == nextDraft)
        #expect(engine.received.isEmpty)

        let settledMessages = chat.messages
        await stalledPhase.finish()
        await preparation.value
        #expect(chat.messages == settledMessages)
        #expect(chat.draftText == nextDraft)
        #expect(engine.received.isEmpty)
        #expect(!chat.isComposerProviderPreparationPending)
    }

    @Test func providerDispatchGateSurvivesLocalCompactionNoOp() async throws {
        var requests = 0
        let admit: ComposerModelPreparationContext.RequestAdmission = { requests += 1 }
        let provider = ComposerModelPreparationContext.gated(MockProvider.shared, beforeRequest: admit)
        let history = [ChatMessageUI(role: .user, content: "owned dispatch fixture")]
        let engine = FallbackChatEngine()

        let unchanged = try await engine.compactContext(
            provider: provider, history: history, systemPrompt: "", keepRecent: 3
        )
        #expect(unchanged.compactedCount == 0)
        #expect(requests == 0)

        _ = try await provider.sendMessage(
            messages: history.map { $0.asLLMMessage() }, systemPrompt: nil,
            maxTokens: 64, temperature: nil
        )
        #expect(requests == 1)

        let stream = try await ComposerModelPreparationContext.$beforeRequest.withValue(admit) {
            try await engine.streamReply(provider: MockProvider.shared, history: history,
                systemPrompt: "", maxTokens: 64)
        }
        for try await _ in stream {}
        #expect(requests == 2)
    }

    @Test("compatible Provider reaches the no-network engine after frozen construction")
    func compatibleProviderUsesFrozenConstruction() async throws {
        let (chat, _) = makeChat()
        let engine = NoNetworkProvider775Engine()
        chat.agentEngine = engine
        let record = EnvVarEntry(
            name: "SYNTHETIC_COMPATIBLE_PRIMARY_806", value: "owned-fixture-key",
            isSecret: true, valueInKeychain: false,
            baseURL: "https://example.invalid",
            modelNames: ["synthetic-model"], protocolType: .openaiCompatible
        )
        chat.selectedCustomProvider = record
        chat.selectedModelID = "synthetic-model"
        chat.draftText = "owned compatible success"
        chat.submitComposer()
        let sessionID = try #require(chat.activeSessionID)
        let execution = try #require(chat.activeExecutionIdentity(for: sessionID))
        let deadline = ContinuousClock.now + .seconds(2)
        while (engine.received.isEmpty || chat.terminalReceipt(for: execution) == nil)
            && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(engine.received.count == 1)
        #expect(engine.received.first?.0 == record.name)
        #expect(engine.received.first?.1 == "synthetic-model")
        #expect(chat.messages.filter { $0.role == .user }.count == 1)
        #expect(chat.draftText.isEmpty)
        #expect(chat.terminalReceipt(for: execution)?.outcome == .succeeded)
        #expect(!chat.isComposerProviderPreparationPending)
    }

    @Test("manual compaction constructs a selected Provider off the actor before the no-network engine")
    func manualCompactionUsesWorkerConstruction() async throws {
        let (chat, _) = makeChat()
        let engine = NoNetworkProvider775Engine()
        chat.agentEngine = engine
        let record = EnvVarEntry(
            name: "SYNTHETIC_COMPACTION_806", value: "owned-fixture-key",
            isSecret: true, valueInKeychain: false,
            baseURL: "https://example.invalid",
            modelNames: ["synthetic-model"], protocolType: .openaiCompatible
        )
        chat.selectedCustomProvider = record
        chat.selectedModelID = "synthetic-model"
        let sessionID = try #require(chat.activeSessionID)
        #expect(chat.setMessages([
            ChatMessageUI(role: .user, content: "First question"),
            ChatMessageUI(role: .assistant, content: "First answer"),
            ChatMessageUI(role: .user, content: "Follow-up question")
        ], forSession: sessionID))
        let held = HeldSubmissionDiagnosticPreflight()
        chat.providerConstructionPauseForTests = { _ = await held.read() }

        chat.compactContext(keepRecent: 1)
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await held.isPending()) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard await held.isPending() else {
            await held.finish()
            Issue.record("manual compaction Provider worker did not start")
            return
        }
        chat.draftText = "editable while Provider preparation is suspended"
        #expect(chat.draftText == "editable while Provider preparation is suspended")
        #expect(engine.compactions.isEmpty)
        await held.finish()
        while engine.compactions.isEmpty && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(engine.compactions.count == 1)
        #expect(engine.compactions.first?.0 == record.name)
        #expect(engine.compactions.first?.1 == "synthetic-model")
    }

    @Test("failed-session retry marks a new execution synchronously while selected Provider construction waits off actor")
    func selectedProviderRetryHasSynchronousIdentityAndAsyncConstruction() async throws {
        let (chat, _) = makeChat()
        let engine = NoNetworkProvider775Engine()
        chat.agentEngine = engine
        let sessionID = try #require(chat.activeSessionID)
        chat.appendUser("owned failed request")
        chat.markExecutionRunning(sessionID: sessionID, turnID: 7, taskID: "old-failed-task")
        chat.markExecutionFailed(sessionID: sessionID, reason: "synthetic failure")
        let failed = try #require(chat.sessionList.first?.retryIdentity)
        let record = EnvVarEntry(
            name: "SYNTHETIC_RETRY_828", value: "owned-fixture-key",
            isSecret: true, valueInKeychain: false,
            baseURL: "https://example.invalid",
            modelNames: ["retry-model"], protocolType: .openaiCompatible
        )
        chat.selectedCustomProvider = record
        chat.selectedModelID = "retry-model"
        let held = HeldSubmissionDiagnosticPreflight()
        chat.providerConstructionPauseForTests = { _ = await held.read() }

        #expect(chat.retryFailedSession(failed))
        #expect(chat.executionSnapshot(forSessionID: sessionID)?.state == .running)
        #expect(chat.executionSnapshot(forSessionID: sessionID)?.taskID != failed.taskID)
        #expect(chat.lastComposerSubmissionSnapshot?.turnID != failed.turnID)
        #expect(chat.messages.filter { $0.role == .user }.count == 1)
        #expect(chat.messages.last?.role == .assistant)
        #expect(chat.messages.last?.isStreaming == true)
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await held.isPending()) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard await held.isPending() else {
            await held.finish()
            Issue.record("retry Provider construction worker did not start")
            return
        }
        chat.draftText = "editable while retry prepares"
        #expect(chat.draftText == "editable while retry prepares")
        #expect(engine.received.isEmpty)
        await held.finish()
        while engine.received.isEmpty && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(engine.received.count == 1)
        #expect(engine.received.first?.0 == record.name)
        #expect(engine.received.first?.1 == "retry-model")
        #expect(chat.messages.filter { $0.role == .user }.count == 1)
    }

    @Test("stopping a held failed-session retry retires its execution before a late Provider result")
    func stoppedSelectedProviderRetryHasNoLateEngineCall() async throws {
        let (chat, _) = makeChat()
        let engine = NoNetworkProvider775Engine()
        chat.agentEngine = engine
        let sessionID = try #require(chat.activeSessionID)
        chat.appendUser("owned stopped retry")
        chat.markExecutionRunning(sessionID: sessionID, turnID: 8, taskID: "old-failed-task")
        chat.markExecutionFailed(sessionID: sessionID, reason: "synthetic failure")
        let failed = try #require(chat.sessionList.first?.retryIdentity)
        let record = EnvVarEntry(
            name: "SYNTHETIC_RETRY_STOP_828", value: "owned-fixture-key",
            isSecret: true, valueInKeychain: false,
            baseURL: "https://example.invalid",
            modelNames: ["retry-model"], protocolType: .openaiCompatible
        )
        chat.selectedCustomProvider = record
        chat.selectedModelID = "retry-model"
        let held = HeldSubmissionDiagnosticPreflight()
        chat.providerConstructionPauseForTests = { _ = await held.read() }

        #expect(chat.retryFailedSession(failed))
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await held.isPending()) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard await held.isPending() else {
            await held.finish()
            Issue.record("retry Provider construction worker did not start")
            return
        }
        let pending = try #require(chat.turnTaskForTests(sessionID: sessionID))
        chat.stopStreaming()
        #expect(chat.executionSnapshot(forSessionID: sessionID)?.state == .idle)
        await held.finish()
        await pending.value
        #expect(engine.received.isEmpty)
        #expect(chat.turnTaskForTests(sessionID: sessionID) == nil)
        #expect(chat.messages.last?.isStreaming == false)
        #expect(chat.messages.filter { $0.role == .user }.count == 1)
    }

    @Test("a credential revision change during failed-session retry discards the held Provider")
    func changedCredentialRevisionRejectsHeldRetry() async throws {
        let (chat, _) = makeChat()
        let engine = NoNetworkProvider775Engine()
        chat.agentEngine = engine
        let sessionID = try #require(chat.activeSessionID)
        chat.appendUser("owned credential revision retry")
        chat.markExecutionRunning(sessionID: sessionID, turnID: 9, taskID: "old-failed-task")
        chat.markExecutionFailed(sessionID: sessionID, reason: "synthetic failure")
        let failed = try #require(chat.sessionList.first?.retryIdentity)
        let record = EnvVarEntry(
            name: "SYNTHETIC_RETRY_REVISION_828", value: "owned-fixture-key",
            isSecret: true, valueInKeychain: false,
            baseURL: "https://example.invalid",
            modelNames: ["retry-model"], protocolType: .openaiCompatible
        )
        chat.selectedCustomProvider = record
        chat.selectedModelID = "retry-model"
        chat.providerRecordsSource = { [record] }
        var revision = "owned-revision-1"
        chat.schedulerCredentialVersionSource = { _ in revision }
        let held = HeldSubmissionDiagnosticPreflight()
        chat.providerConstructionPauseForTests = { _ = await held.read() }

        #expect(chat.retryFailedSession(failed))
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await held.isPending()) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard await held.isPending() else {
            await held.finish()
            Issue.record("retry Provider construction worker did not start")
            return
        }
        let pending = try #require(chat.turnTaskForTests(sessionID: sessionID))
        revision = "owned-revision-2"
        await held.finish()
        await pending.value
        #expect(chat.executionSnapshot(forSessionID: sessionID)?.state == .idle)
        #expect(chat.messages.last?.isStreaming == false)
        #expect(chat.turnTaskForTests(sessionID: sessionID) == nil)
        #expect(engine.received.isEmpty)
    }

    @Test("a held failed-session retry cannot resume into a newly selected session")
    func switchedSessionRejectsHeldRetry() async throws {
        let (chat, _) = makeChat()
        let engine = NoNetworkProvider775Engine()
        chat.agentEngine = engine
        let sessionID = try #require(chat.activeSessionID)
        chat.appendUser("owned original session retry")
        chat.markExecutionRunning(sessionID: sessionID, turnID: 10, taskID: "old-failed-task")
        chat.markExecutionFailed(sessionID: sessionID, reason: "synthetic failure")
        let failed = try #require(chat.sessionList.first?.retryIdentity)
        chat.selectedCustomProvider = EnvVarEntry(
            name: "SYNTHETIC_RETRY_SWITCH_828", value: "owned-fixture-key",
            isSecret: true, valueInKeychain: false,
            baseURL: "https://example.invalid",
            modelNames: ["retry-model"], protocolType: .openaiCompatible
        )
        chat.selectedModelID = "retry-model"
        let held = HeldSubmissionDiagnosticPreflight()
        chat.providerConstructionPauseForTests = { _ = await held.read() }

        #expect(chat.retryFailedSession(failed))
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await held.isPending()) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard await held.isPending() else {
            await held.finish()
            Issue.record("retry Provider construction worker did not start")
            return
        }
        let pending = try #require(chat.turnTaskForTests(sessionID: sessionID))
        chat.newSession()
        let newSessionID = try #require(chat.activeSessionID)
        #expect(newSessionID != sessionID)
        await held.finish()
        await pending.value
        #expect(engine.received.isEmpty)
        #expect(chat.turnTaskForTests(sessionID: sessionID) == nil)
        #expect(chat.messages.allSatisfy { $0.role != .assistant })
        #expect(chat.sessions.first(where: { $0.id == sessionID })?.messages.last?.isStreaming == false)
        #expect(chat.executionSnapshot(forSessionID: sessionID)?.state == .idle)
    }

    @Test("opt-in distinguishes asynchronous credential identity rejection")
    func supersededPreflightHasTypedReason() async throws {
        let (chat, logger) = makeChat()
        chat.composerSubmissionDiagnosticsEnabled = true
        let record = EnvVarEntry(
            name: "SYNTHETIC_PROVIDER_261", value: "", isSecret: true,
            valueInKeychain: true, baseURL: "https://example.invalid",
            modelNames: ["synthetic-model"], protocolType: .openaiCompatible
        )
        chat.selectedCustomProvider = record
        chat.providerRecordsSource = { [record] }
        var revision = "synthetic-revision"
        chat.schedulerCredentialVersionSource = { _ in revision }
        let held = HeldSubmissionDiagnosticPreflight()
        chat.providerCredentialPreflightSource = { _, _, _ in await held.read() }
        chat.draftText = draftSentinel
        let owner = try #require(chat.activeSessionID)

        chat.submitComposer()
        let startDeadline = ContinuousClock.now + .seconds(2)
        while !(await held.isPending()) && ContinuousClock.now < startDeadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let started = await held.isPending()
        chat.newSession()
        revision = "rebound-revision"
        await held.finish()
        #expect(started)
        guard started else { return }

        let deadline = ContinuousClock.now + .seconds(2)
        while !stageMessages(logger).contains(where: {
            $0.contains("stage=credentialPreflightRejected "
                + "reason=credentialRecordChanged")
        }) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let entries = stageMessages(logger)
        #expect(entries.contains { $0.contains("stage=credentialPreflightStarted")
            && $0.contains(protectedSessionField(owner)) })
        #expect(entries.contains { $0.contains("stage=credentialPreflightRejected "
            + "reason=credentialRecordChanged")
            && $0.contains(protectedSessionField(owner)) })
        #expect(entries.allSatisfy { !$0.contains(owner.uuidString) })
        #expect(chat.messages.allSatisfy { $0.role != .user })
        let original = try #require(chat.sessions.first { $0.id == owner })
        #expect(original.messages.filter { $0.role == .user }.count == 1)
        #expect(original.messages.last?.isStreaming == false)
        #expect(original.messages.last?.content.contains("错误") == true)
        assertNoPayload(entries)
    }
}
