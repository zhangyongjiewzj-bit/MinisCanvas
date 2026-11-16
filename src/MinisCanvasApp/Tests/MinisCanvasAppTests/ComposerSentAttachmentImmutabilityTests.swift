import Foundation
import CryptoKit
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class SentAttachmentOfflineProvider: LLMProvider, @unchecked Sendable {
    let name = "sent-attachment-fixture"
    var model = LLMModel(
        id: "sent-attachment-fixture", displayName: "Sent Attachment Fixture",
        provider: "test", modalityOverride: .vision
    )

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "fixture", stopReason: "end_turn", usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}

private final class SentAttachmentCaptureEngine: ComposerSnapshotForwardingTestEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedHistories: [[ChatMessageUI]] = []

    var firstHistory: [ChatMessageUI]? { lock.withLock { capturedHistories.first } }
    var isAvailable: Bool { true }

    func streamReply(
        provider: any LLMProvider, history: [ChatMessageUI], systemPrompt: String, maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        record(history)
    }

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int,
        conversationID: String?,
        authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?,
        turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        record(history)
    }

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int,
        conversationID: String?,
        authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?,
        turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot,
        executionIdentity: AgentExecutionIdentity
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        record(history)
    }

    func interrupt() {}

    func compactContext(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        keepRecent: Int
    ) async -> CompactionResult {
        CompactionResult(messages: [], summary: nil, compactedCount: 0)
    }

    private func record(_ history: [ChatMessageUI]) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        lock.withLock { capturedHistories.append(history) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.done(stopReason: .endTurn))
            continuation.finish()
        }
    }
}

@Suite("D-COMPOSER-14 sent attachment immutability")
@MainActor
struct ComposerSentAttachmentImmutabilityTests {
    private func offlineChat() -> (ChatStore, SentAttachmentCaptureEngine) {
        let chat = ChatStore()
        let engine = SentAttachmentCaptureEngine()
        chat.agentEngine = engine
        chat.streamingProviderOverride = SentAttachmentOfflineProvider()
        return (chat, engine)
    }

    private func pendingImage(id: UUID = UUID()) -> ChatAttachment {
        ChatAttachment(
            id: id,
            kind: .file,
            fileName: "synthetic.png",
            fileType: .image,
            mimeType: "image/png",
            size: nil,
            fileURL: "/synthetic/synthetic.png",
            status: .pending
        )
    }

    private func resolvedImage(id: UUID, bytes: Data, status: ChatAttachment.Status = .ready) -> ChatAttachment {
        ChatAttachment(
            id: id,
            kind: status == .ready ? .image : .file,
            fileName: "synthetic.png",
            fileType: .image,
            mimeType: "image/png",
            size: Int64(bytes.count),
            data: status == .ready ? bytes : nil,
            fileURL: "/synthetic/synthetic.png",
            status: status
        )
    }

    @Test func invalidResolvedPNGRemainsBlockedWithoutConsumingDraft() throws {
        let (chat, engine) = offlineChat()
        let owner = try #require(chat.activeSessionID)
        let pending = pendingImage()
        let oldInvalidBytes = Data([1, 2, 3, 4])
        let invalid = resolvedImage(id: pending.id, bytes: oldInvalidBytes)
        chat.draftText = "owned invalid image"; chat.addComposerDraftAttachment(pending)
        chat.applyComposerAttachmentResolution(invalid, sessionID: owner)
        #expect(MediaPayloadValidation.failure(data: oldInvalidBytes, mimeType: "image/png") != nil)
        #expect(!chat.canSubmitComposerAttachments)
        chat.submitComposer()
        #expect(chat.pendingAttachments == [invalid])
        #expect(chat.draftText == "owned invalid image")
        #expect(chat.messages.allSatisfy { $0.role != .user })
        #expect(chat.lastComposerSubmissionSnapshot == nil)
        #expect(engine.firstHistory == nil)
    }

    @Test("pending resolution blocks model and both Composer send predicates without consuming the draft")
    func pendingNeedsAnotherExplicitSubmit() async throws {
        let (chat, engine) = offlineChat()
        let owner = try #require(chat.activeSessionID)
        let pending = pendingImage()
        chat.draftText = "请看图片"
        chat.addComposerDraftAttachment(pending)

        #expect(!chat.canSubmitComposerAttachments)
        #expect(!GlobalComposer.canSend(
            draftText: chat.draftText,
            pendingAttachmentCount: chat.pendingAttachments.count,
            attachmentsReady: chat.canSubmitComposerAttachments
        ))
        chat.submitComposer()
        #expect(chat.messages.allSatisfy { $0.role != .user })
        #expect(chat.lastComposerSubmissionSnapshot == nil)
        #expect(engine.firstHistory == nil)
        #expect(chat.draftText == "请看图片")
        #expect(chat.pendingAttachments == [pending])

        let payload = try ComposerMediaFixtures589.png(color: 0.25)
        #expect(MediaPayloadValidation.failure(data: payload, mimeType: "image/png") == nil)
        let resolved = resolvedImage(id: pending.id, bytes: payload)
        chat.applyComposerAttachmentResolution(resolved, sessionID: owner)
        #expect(chat.canSubmitComposerAttachments)
        #expect(chat.pendingAttachments == [resolved])
        #expect(chat.messages.allSatisfy { $0.role != .user }) // no delayed automatic send

        chat.submitComposer()
        let sent = try #require(chat.messages.last(where: { $0.role == .user }))
        let frozenAtSubmit = resolved.withDeliveryQuarantined(true)
        #expect(sent.content.contains("请看图片"))
        #expect(sent.attachments == [frozenAtSubmit])
        #expect(sent.attachments.first?.id == pending.id)
        #expect(sent.attachments.first?.deliveryQuarantined == true)
        #expect(sent.llmImages.first?.data == payload)
        #expect(chat.pendingAttachments.isEmpty)
        #expect(chat.draftText.isEmpty)
        #expect(chat.lastComposerSubmissionSnapshot?.messageID == sent.id.uuidString)
        for _ in 0..<50 where engine.firstHistory == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let firstRequest = try #require(engine.firstHistory?.last(where: { $0.role == .user }))
        #expect(firstRequest.id == sent.id)
        #expect(firstRequest.attachments == [frozenAtSubmit])
        #expect(firstRequest.asLLMMessage().images.first?.data == payload)
    }

    @Test("late and duplicate callbacks cannot change sent bytes, persisted sidecar or future replay")
    func sentPayloadStaysFrozenAcrossLateResultAndSessionSwitch() throws {
        let (chat, _) = offlineChat()
        let owner = try #require(chat.activeSessionID)
        let pending = pendingImage()
        let payload = try ComposerMediaFixtures589.png(color: 0.25)
        #expect(MediaPayloadValidation.failure(data: payload, mimeType: "image/png") == nil)
        let resolved = resolvedImage(id: pending.id, bytes: payload)
        chat.draftText = "冻结载荷"
        chat.addComposerDraftAttachment(pending)
        chat.applyComposerAttachmentResolution(resolved, sessionID: owner)
        chat.submitComposer()

        let sent = try #require(chat.messages.last(where: { $0.role == .user }))
        let frozenAtSubmit = resolved.withDeliveryQuarantined(true)
        #expect(sent.attachments == [frozenAtSubmit])
        #expect(sent.attachments.first?.deliveryQuarantined == true)
        let digest = try #require(chat.lastComposerSubmissionSnapshot?.inputDigest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sidecarBytes = try encoder.encode(sent)
        let replayed = try JSONDecoder().decode(ChatMessageUI.self, from: sidecarBytes)
        #expect(replayed.attachments == [frozenAtSubmit])
        #expect(replayed.asLLMMessage().images.first?.data == payload)

        let duplicate = resolvedImage(id: pending.id, bytes: try ComposerMediaFixtures589.png(color: 0.85))
        chat.applyComposerAttachmentResolution(duplicate, sessionID: owner)
        chat.beginEdit(messageID: sent.id)
        chat.applyComposerAttachmentResolution(duplicate, sessionID: owner)
        let otherSession = chat.applyNewSession(title: "another")
        #expect(chat.activeSessionID == otherSession)
        chat.applyComposerAttachmentResolution(duplicate, sessionID: owner)
        chat.switchSession(id: owner)

        let unchanged = try #require(chat.messages.last(where: { $0.id == sent.id }))
        #expect(unchanged == sent)
        let unchangedSidecarBytes = try encoder.encode(unchanged)
        #expect(unchangedSidecarBytes == sidecarBytes)
        #expect(unchanged.asLLMMessage().images.first?.data == payload)
        #expect(chat.lastComposerSubmissionSnapshot?.inputDigest == digest)
    }

    @Test("failure remains failed until explicit removal and retry; it never silently sends")
    func failedResolutionRequiresUserAction() throws {
        let (chat, engine) = offlineChat()
        let owner = try #require(chat.activeSessionID)
        let pending = pendingImage()
        chat.draftText = "稍后再发"
        chat.addComposerDraftAttachment(pending)

        let failed = resolvedImage(id: pending.id, bytes: Data(), status: .failed)
        chat.applyComposerAttachmentResolution(failed, sessionID: owner)
        chat.applyComposerAttachmentResolution(resolvedImage(id: pending.id, bytes: try ComposerMediaFixtures589.png(color: 0.25)), sessionID: owner)
        #expect(chat.pendingAttachments == [failed])
        #expect(chat.composerAttachmentBlockReason != nil)
        chat.submitComposer()
        #expect(chat.messages.allSatisfy { $0.role != .user })
        #expect(engine.firstHistory == nil)
        #expect(chat.draftText == "稍后再发")

        chat.removePendingAttachment(id: pending.id)
        #expect(chat.messages.allSatisfy { $0.role != .user })
        #expect(chat.draftText == "稍后再发")
        let retry = pendingImage()
        chat.addComposerDraftAttachment(retry)
        #expect(!chat.canSubmitComposerAttachments)
        chat.applyComposerAttachmentResolution(resolvedImage(id: retry.id, bytes: try ComposerMediaFixtures589.png(color: 0.75)), sessionID: owner)
        #expect(chat.messages.allSatisfy { $0.role != .user })
        chat.submitComposer()
        #expect(chat.messages.last(where: { $0.role == .user })?.attachments.first?.id == retry.id)
    }
}


// TASK0715: the Provider boundary is controlled; ChatStore, prompt worker,
// AgentLoop and canonical/attachment persistence remain the production path.
private final class Composer14PreparationGate0715: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    var isPaused: Bool { lock.withLock { continuation != nil } }
    func wait() async {
        await withCheckedContinuation { next in
            let immediate = lock.withLock {
                if released { return true }
                continuation = next
                return false
            }
            if immediate { next.resume() }
        }
    }
    func release() {
        let parked = lock.withLock {
            released = true
            let value = continuation
            continuation = nil
            return value
        }
        parked?.resume()
    }
}

private final class Composer14RequestProvider0715: LLMProvider, @unchecked Sendable {
    struct Request: Sendable { let messages: [LLMMessage] }
    let name = "composer14-owned-provider-0715"
    var model = LLMModel(id: "composer14-owned-model-0715", displayName: "Owned Composer14",
        provider: "composer14-owned-provider-0715")
    var capabilities: Set<ProviderCapability> { [.tools] }
    private let lock = NSLock()
    private var captured: [Request] = []
    private var streams = 0
    var requests: [Request] { lock.withLock { captured } }
    var streamCallCount: Int { lock.withLock { streams } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { captured.append(Request(messages: messages)) }
        return LLMResponse(text: "0715 owned completion", stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
            maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        lock.withLock { streams += 1 }
        return AsyncThrowingStream { $0.finish() }
    }
}

extension ComposerSentAttachmentImmutabilityTests {
    private func contextSettingsOwner0715(
        root: URL, profile: RuntimeIsolationProfile, sessionStore: SessionStore,
        memory: MemoryStore, skills: SkillStore, log: LogManager,
        defaults: UserDefaults, badges: SessionBadgeStore, readiness: ProviderReadinessStore
    ) -> SettingsCenter {
        let keychain = profile.makeKeychainStore() // production in-memory disposable composition
        return SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("providers"), keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: memory,
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: sessionStore, sessionBadgeStore: badges, logManager: log,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp.json"), keychain: keychain),
            skillStore: skills, usageStore: UsageStore(domain: .suite(root.lastPathComponent)),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock, providerReadinessStore: readiness
        )
    }

    private func wait0715(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "owned ordinary consumer reached its bounded phase")
    }

    @Test("held send edits become only the next real request; stale callbacks cannot rewrite disk ownership")
    func heldEditBecomesNextOrdinaryRequestAndFreshDiskOwnership0715() async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("composer14-0715-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let defaults = try #require(UserDefaults(suiteName: "composer14-0715-" + root.lastPathComponent))
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let a = UUID(), b = UUID()
        for id in [a, b] {
            _ = try sessions.createSession(id: id.uuidString, title: "Owned Composer14",
                projectID: "composer14-owned", projectName: "Synthetic Composer14", workingDirectory: root.path)
        }
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        let drafts = DraftStore(directory: root.appendingPathComponent("drafts"))
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let log = LogManager(directory: root.appendingPathComponent("logs"))
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let souls = SoulStore(directory: root.appendingPathComponent("souls"))
        let chat = ChatStore(providerReadinessStore: readiness, preferencesDefaults: defaults, logManager: log)
        defer { chat.stopAllStreamingForSafety() }
        #expect(chat.attachPersistence(sessions, badgeStore: badges))
        chat.attachDraftStore(drafts)
        chat.restoreSpeedTier(.fast)
        let manager = try #require(chat.sessionManager)
        #expect(manager.store === sessions && manager.store.directory == sessions.directory)
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "composer14-0715-policy", grantEpoch: "composer14-0715-epoch",
            leaseID: "composer14-0715-lease", expiresAt: .distantFuture, autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = .init(mode: .plan, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        let tasks = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        chat.agentEngine = AgentLoopChatEngine(
            toolExecutor: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []), taskStore: tasks,
            chatRuntimeDependencies: .init(sessionStore: sessions, memoryStore: memory,
                skillStore: skills, soulStore: souls),
            contextWritebackStorePersistenceURL: root.appendingPathComponent("context.json"),
            toolExecutionFactLedger: ledger, composerPolicyFacts: facts).withRequestBudget(chat.budgetTracker)
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        let provider = Composer14RequestProvider0715()
        // This actual ordinary runtime needs the canonical Settings owner
        // composed for its SessionStore, as production Bridge composition does.
        let contextOwner = contextSettingsOwner0715(root: root, profile: profile,
            sessionStore: sessions, memory: memory, skills: skills, log: log,
            defaults: defaults, badges: badges, readiness: readiness)
        defer { withExtendedLifetime(contextOwner) {} }
        #expect(contextOwner.sessionStore.directory == sessions.directory)
        let contextResolution = SettingsCenter.contextTurnSettingsSnapshot(
            for: sessions, sessionID: a.uuidString, model: provider.model)
        let acceptedSettings: ContextTurnSettingsSnapshot?
        if case .accepted(let snapshot) = contextResolution { acceptedSettings = snapshot }
        else { acceptedSettings = nil }
        let ownedSettings = try #require(acceptedSettings)
        #expect(ownedSettings.sessionID == a.uuidString)
        #expect(ownedSettings.modelID == provider.model.id)
        chat.streamingProviderOverride = provider
        let originalText = "COMPOSER14_0715_ORIGINAL_A"
        let nextText = "COMPOSER14_0715_TYPED_WHILE_HELD_NEXT_A"
        let bText = "COMPOSER14_0715_UNSENT_B"
        let material = Data("COMPOSER14_0715_ORIGINAL_ATTACHMENT".utf8)
        let source = root.appendingPathComponent("owned-a.md")
        try material.write(to: source)
        let attachment = ChatAttachment(kind: .text, fileName: source.lastPathComponent, fileType: .markdown,
            size: Int64(material.count), data: material, fileURL: source.path)
        #expect(chat.applySwitchSession(id: b))
        chat.draftText = bText
        #expect(chat.flushPendingDraftForTermination() && drafts.flushAll())
        let bKey = DraftStore.chatDraftKey(sessionID: b)
        let bDraft = try #require(drafts.load(key: bKey))
        #expect(chat.applySwitchSession(id: a))
        chat.draftText = originalText
        chat.addComposerDraftAttachment(attachment)
        let gate = Composer14PreparationGate0715()
        defer { gate.release() }
        chat.turnPromptPreprocessPauseForTests = { await gate.wait() }
        chat.submitComposer()
        let firstSnapshot = try #require(chat.lastComposerSubmissionSnapshot)
        let first = try #require(chat.messages(forSession: a)?.last(where: { $0.role == .user }))
        #expect(firstSnapshot.sessionID == a.uuidString && firstSnapshot.messageID == first.id.uuidString)
        #expect(firstSnapshot.mode == .plan && firstSnapshot.approvalScope == .request)
        #expect(firstSnapshot.policyRevision == facts.revision && firstSnapshot.grantEpoch == facts.grantEpoch)
        #expect(firstSnapshot.hasRequiredPolicyIdentity && !firstSnapshot.bypassModeConfirmed)
        let firstDigest = try #require(firstSnapshot.inputDigest)
        #expect(chat.draftText.isEmpty && chat.pendingAttachments.isEmpty)
        try await wait0715 { gate.isPaused }
        let firstExecution = try #require(chat.activeExecutionIdentity(for: a))
        #expect(firstExecution.turn.messageID == firstSnapshot.messageID)
        #expect(provider.requests.isEmpty)
        chat.draftText = nextText
        #expect(chat.applySwitchSession(id: b))
        #expect(chat.draftText == bText && chat.pendingAttachments.isEmpty)
        let aURL = sessions.sessionsDirectory.appendingPathComponent(a.uuidString + ".json")
        let bURL = sessions.sessionsDirectory.appendingPathComponent(b.uuidString + ".json")
        let sidecarURL = ChatAttachmentPersistence.sessionSidecarURL(for: a, in: sessions.directory)
        let heldABytes = try Data(contentsOf: aURL)
        let heldBBytes = try Data(contentsOf: bURL)
        let heldSidecarBytes = try Data(contentsOf: sidecarURL)
        let poison = "COMPOSER14_0715_LATE_CALLBACK_POISON"
        let late = ChatAttachment(id: attachment.id, kind: .text, fileName: attachment.fileName,
            fileType: .markdown, data: Data(poison.utf8), fileURL: source.path)
        chat.applyComposerAttachmentResolution(late, sessionID: a)
        chat.applyComposerAttachmentResolution(late, sessionID: b)
        #expect(chat.messages(forSession: a)?.first(where: { $0.id == first.id }) == first)
        #expect(chat.lastComposerSubmissionSnapshot == firstSnapshot)
        #expect(chat.draftText == bText && chat.pendingAttachments.isEmpty)
        #expect(try Data(contentsOf: aURL) == heldABytes)
        #expect(try Data(contentsOf: bURL) == heldBBytes)
        #expect(try Data(contentsOf: sidecarURL) == heldSidecarBytes)
        #expect(provider.requests.isEmpty)
        chat.turnPromptPreprocessPauseForTests = nil
        gate.release()
        try await wait0715 {
            provider.requests.count == 1 && chat.messages(forSession: a)?.last(where: {
                $0.role == .assistant
            })?.turnTiming?.finishedAt != nil
        }
        let firstWire = try #require(provider.requests.first?.messages.last(where: { $0.role == .user }))
        #expect(firstWire == first.asLLMMessage())
        #expect(firstWire.content.contains(originalText) && firstWire.content.contains(String(decoding: material, as: UTF8.self)))
        #expect(!firstWire.content.contains(nextText) && !firstWire.content.contains(poison) && !firstWire.content.contains(bText))
        #expect(chat.draftText == bText && drafts.load(key: bKey) == bDraft)
        #expect(try Data(contentsOf: bURL) == heldBBytes)
        #expect(chat.applySwitchSession(id: a))
        #expect(chat.draftText == nextText && chat.pendingAttachments.isEmpty)
        let firstRecords = try #require(try ChatAttachmentPersistence.load(forSessionID: a.uuidString, from: sessions.directory))
        let firstRecord = try #require(firstRecords.first(where: { $0.attachments.contains(where: { $0.id == attachment.id }) }))
        let canonicalFirst = try #require(sessions.loadSession(id: a.uuidString))
        try #require(canonicalFirst.messages.indices.contains(firstRecord.messageIndex))
        #expect(canonicalFirst.messages[firstRecord.messageIndex] == firstWire)
        #expect(firstRecord.attachments == [attachment])
        let contentDigest = SHA256.hash(data: Data(first.content.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(firstRecord.contentDigest == contentDigest)
        let completeFirstBytes = try Data(contentsOf: aURL)
        let completeFirstSidecar = try Data(contentsOf: sidecarURL)
        chat.applyComposerAttachmentResolution(late, sessionID: a)
        #expect(chat.draftText == nextText && chat.pendingAttachments.isEmpty)
        #expect(try Data(contentsOf: aURL) == completeFirstBytes)
        #expect(try Data(contentsOf: sidecarURL) == completeFirstSidecar)

        // This is the missing consumer: submit the text typed during the held
        // first send, through the same ordinary ChatStore/AgentLoop path.
        chat.submitComposer()
        let secondSnapshot = try #require(chat.lastComposerSubmissionSnapshot)
        let second = try #require(chat.messages(forSession: a)?.last(where: { $0.role == .user }))
        #expect(second.id != first.id && secondSnapshot.messageID == second.id.uuidString)
        #expect(secondSnapshot.sessionID == a.uuidString && secondSnapshot.taskID != firstSnapshot.taskID)
        #expect(secondSnapshot.inputDigest != firstDigest && secondSnapshot.attemptID != firstSnapshot.attemptID)
        #expect(secondSnapshot.mode == .plan && secondSnapshot.approvalScope == .request)
        #expect(secondSnapshot.policyRevision == facts.revision && secondSnapshot.grantEpoch == facts.grantEpoch)
        #expect(secondSnapshot.hasRequiredPolicyIdentity && !secondSnapshot.bypassModeConfirmed)
        #expect(second.content == nextText && second.attachments.isEmpty)
        try await wait0715 {
            provider.requests.count == 2 && chat.messages(forSession: a)?.last(where: {
                $0.role == .assistant
            })?.turnTiming?.finishedAt != nil
        }
        let secondWire = try #require(provider.requests.last?.messages.last(where: { $0.role == .user }))
        #expect(secondWire == second.asLLMMessage() && secondWire.content == nextText)
        #expect(secondWire.images.isEmpty && !secondWire.content.contains(poison) && !secondWire.content.contains(originalText))
        #expect(provider.requests.count == 2 && provider.streamCallCount == 0)
        let canonical = try #require(sessions.loadSession(id: a.uuidString))
        #expect(canonical.messages[firstRecord.messageIndex] == firstWire)
        let records = try #require(try ChatAttachmentPersistence.load(forSessionID: a.uuidString, from: sessions.directory))
        #expect(records.first(where: { $0.messageIndex == firstRecord.messageIndex }) == firstRecord)
        let secondIndex = try #require(canonical.messages.lastIndex(of: secondWire))
        #expect(secondIndex > firstRecord.messageIndex && second.attachments.isEmpty)
        #expect(second.trustedSessionReadIntent == nil)
        let plainDigest = SHA256.hash(data: Data(canonical.messages[secondIndex].content.utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(records.first(where: { $0.messageIndex == secondIndex }) == ChatAttachmentPersistence.MessageRecord(
            messageIndex: secondIndex, contentDigest: plainDigest, attachments: [], producerTextAttachmentCount: 0))
        #expect(canonical.messages[secondIndex] == secondWire)
        let terminalRecord = try #require(records.last(where: { $0.turnTiming != nil }))
        try #require(canonical.messages.indices.contains(terminalRecord.messageIndex))
        #expect(canonical.messages[terminalRecord.messageIndex].role == .assistant)
        #expect(terminalRecord.turnTiming?.timing.finishedAt != nil)
        #expect(terminalRecord.turnTiming?.modelID == provider.model.id)
        let assistantDigest = SHA256.hash(data: Data(canonical.messages[terminalRecord.messageIndex].content.utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(terminalRecord.contentDigest == assistantDigest)
        let secondDigest = SHA256.hash(data: Data(second.content.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(records.allSatisfy { !$0.attachments.contains(where: { $0.id == attachment.id && $0.data != material }) })
        #expect(try Data(contentsOf: bURL) == heldBBytes && drafts.load(key: bKey) == bDraft)
        #expect(chat.messages(forSession: b)?.isEmpty == true)

        let freshSessions = SessionStore(directory: sessions.directory)
        let reloadedSession = try #require(freshSessions.loadSession(id: a.uuidString))
        try #require(reloadedSession.messages.indices.contains(secondIndex))
        let reloadedSecond = reloadedSession.messages[secondIndex]
        #expect(reloadedSecond == secondWire)
        let actualSecondDigest = SHA256.hash(data: Data(reloadedSecond.content.utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(actualSecondDigest == secondDigest)
        let reopened = ChatStore(providerReadinessStore: readiness, preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("fresh-logs")))
        defer { reopened.stopAllStreamingForSafety() }
        #expect(reopened.attachPersistence(freshSessions, badgeStore: badges))
        #expect(reopened.applySwitchSession(id: a))
        let restoredFirst = try #require(reopened.messages.first(where: { $0.role == .user && $0.content == first.content }))
        let restoredSecond = try #require(reopened.messages.first(where: { $0.role == .user && $0.content == nextText }))
        #expect(restoredFirst.asLLMMessage() == firstWire && restoredFirst.attachments == [attachment])
        #expect(restoredSecond.asLLMMessage() == secondWire && restoredSecond.attachments.isEmpty)
        #expect(restoredSecond.turnTiming == second.turnTiming)
        #expect(reopened.messages.last(where: { $0.role == .assistant })?.turnTiming?.finishedAt != nil)
        #expect(chat.composerPolicyFacts == facts && ledger.facts.isEmpty)
        #expect(reopened.applySwitchSession(id: b))
        #expect(reopened.messages.isEmpty)
        print("COMPOSER14_0715 original=\(first.id) next=\(second.id) attachment=\(attachment.id) session=\(a) neighbor=\(b) digest=\(contentDigest) nextDigest=\(secondDigest) requests=\(provider.requests.count) diskSidecar=\(sidecarURL.path)")
    }
}
