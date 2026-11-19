import Foundation
import os
@testable import MinisCore
import Testing
@testable import MinisCanvasApp

/// Compose the real settings owner on the same canonical session root. These
/// consumers must not depend on a prior suite having released SettingsCenter.active.
@MainActor
private func contextSettingsOwner663(root: URL, sessions: SessionStore,
    skills: SkillStore, defaults: UserDefaults, log: LogManager) -> SettingsCenter {
    let keychain = KeychainStore(backing: InMemoryKeychainBacking())
    return SettingsCenter(
        settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
        envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain,
            privacyStore: EnvVarPrivacyStore(defaults: defaults)),
        memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
        memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
        sessionStore: sessions,
        sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
        logManager: log,
        mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
        skillStore: skills,
        usageStore: UsageStore(domain: .suite("ctx663-settings-\(UUID().uuidString)")),
        shortcutStore: ShortcutStore(defaults: defaults),
        providerReadinessTransport: FailClosedProviderReadinessTransport(),
        providerReadinessDeployment: .mock,
        providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("env")))
}

/// D-CTX2: the real manifest cache feeds the existing ChatStore/AgentLoop request
/// boundary. No second cache, runtime, SDK, credential store, or external request.
@Suite("CTX2 cached context at the ChatStore request consumer")
@MainActor
struct ContextCacheChatStore663Tests {
    enum Drift: Sendable, CaseIterable { case session, model }

    private func chat(root: URL) throws -> ChatStore {
        let defaults = try #require(UserDefaults(suiteName: "ctx663-\(UUID().uuidString)"))
        let chat = ChatStore(preferencesDefaults: defaults, logManager: LogManager(directory: root))
        chat.configureComposerPolicy(ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "ctx663-policy",
            grantEpoch: "ctx663-grant", leaseID: "ctx663-lease",
            expiresAt: .distantFuture, autonomyCeiling: .l3
        ))
        return chat
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctx663-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root // Owned synthetic files are retained for failed-run diagnosis.
    }

    private func snapshot(session: UUID, model: String = "ctx663-model-a",
                          epoch: String = "owned-epoch-a") -> ConversationContextSnapshotV1 {
        ConversationContextSnapshotV1(sessionID: session.uuidString,
            providerID: "ctx663-provider", modelID: model,
            configurationFingerprint: epoch, skillIdentifiers: [],
            conversationID: session.uuidString)
    }

    private func build(_ cache: ContextOrchestrator, snapshot: ConversationContextSnapshotV1,
                       scope: String, text: String = "owned cached context") -> ContextOrchestrator.Result {
        cache.makeManifest(.init(snapshot: snapshot, contextItems: [ContextItem(
            identifier: "memory", content: text, tokenCost: 4,
            scope: scope, provenance: "synthetic-ctx663", required: true
        )]), budget: 64)
    }

    private func settle(_ chat: ChatStore) async throws {
        for _ in 0..<200 {
            if !chat.isStreaming { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!chat.isStreaming, "owned local provider did not reach a terminal state")
    }

    private func submit(_ chat: ChatStore, provider: ContextRequestProvider663,
                        snapshot: ConversationContextSnapshotV1,
                        result: ContextOrchestrator.Result, runID: String) async throws {
        chat.agentEngine = AgentLoopChatEngine(contextManifestInput: .init(
            snapshot: snapshot, result: result, runID: runID
        ), composerPolicyFacts: chat.composerPolicyFacts)
        chat.streamingProviderOverride = provider
        chat.draftText = "owned context request"
        chat.submitComposer()
        try await settle(chat)
    }

    /// Read keys actually written by the production store, independently of the
    /// generated-key formula. All bytes belong to this synthetic fixture.
    private func retainedRunIDs(_ url: URL) throws -> Set<String> {
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let records = try #require(envelope["records"] as? [String: Any])
        return Set(records.keys)
    }

    @Test func switchingBackUsesTheOriginalQuotaForTheNextRealProviderAdmission() async throws {
        let directory = try root()
        let chat = try chat(root: directory)
        defer { chat.stopAllStreamingForSafety() }
        chat.newSession()
        let a = try #require(chat.activeSessionID)
        let skills = SkillStore(skillsRoot: directory.appendingPathComponent("skills"))
        chat.agentEngine = AgentLoopChatEngine(requestBudget: chat.budgetTracker,
            composerPolicyFacts: chat.composerPolicyFacts)
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        let probe = ContextSourcesProbe663(toolOnFirstCall: false)
        chat.streamingProviderOverride = ContextSourcesProvider663(probe: probe)
        for text in ["owned A first", "owned A second"] {
            chat.draftText = text; chat.submitComposer(); try await settle(chat)
        }
        let trackerA = chat.budgetTracker
        #expect(await trackerA.budget.usedTokens == 305)
        chat.newSession()
        let b = try #require(chat.activeSessionID)
        let trackerB = chat.budgetTracker
        #expect(trackerB !== trackerA && chat.budgetUsedTokens == 0)
        chat.draftText = "owned B first"; chat.submitComposer(); try await settle(chat)
        #expect(await trackerB.budget.usedTokens == 304)
        // The current legal default applies on restoration, without renewing A.
        chat.setTokenBudgetLimit(305, unlimited: false)
        #expect(chat.applySwitchSession(id: a))
        chat.draftText = "A must remain exhausted"; chat.submitComposer(); try await settle(chat)
        #expect(chat.budgetTracker === trackerA)
        #expect(chat.budgetUsedTokens == 305 && chat.budgetRequestCount == 2)
        #expect(chat.budgetIsOverLimit && chat.contextLimitReason != nil)
        #expect(await probe.snapshot().count == 3)
        #expect(chat.applySwitchSession(id: b))
        chat.draftText = "B still has its own remaining quota"; chat.submitComposer(); try await settle(chat)
        #expect(chat.budgetTracker === trackerB)
        #expect(await probe.snapshot().count == 4)
        #expect(await trackerB.budget.usedTokens == 709)
        #expect(await trackerA.budget.usedTokens == 305)
    }

    @Test func inactiveSettlementAndCancelledLateResponseStayWithTheirOriginalSessionOwner() async throws {
        let directory = try root()
        let chat = try chat(root: directory)
        let probe = ContextSourcesProbe663(toolOnFirstCall: false)
        defer {
            chat.stopAllStreamingForSafety()
            Task { await probe.releaseHeldResponse() }
        }
        chat.newSession()
        let a = try #require(chat.activeSessionID)
        let trackerA = chat.budgetTracker
        let skills = SkillStore(skillsRoot: directory.appendingPathComponent("skills"))
        chat.agentEngine = AgentLoopChatEngine(requestBudget: trackerA, composerPolicyFacts: chat.composerPolicyFacts)
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        chat.streamingProviderOverride = ContextSourcesProvider663(probe: probe)
        await probe.holdNextResponse()
        chat.draftText = "owned A held response"; chat.submitComposer()
        let firstTask = try #require(chat.turnTaskForTests(sessionID: a))
        for _ in 0..<200 {
            if await probe.snapshot().count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await probe.snapshot().count == 1)
        #expect(await trackerA.pendingRequestCount == 1)
        chat.newSession()
        let b = try #require(chat.activeSessionID)
        let trackerB = chat.budgetTracker
        chat.draftText = "owned B independent request"; chat.submitComposer(); try await settleActiveOwner663(chat, session: b)
        #expect(await trackerB.budget.usedTokens == 203)
        await probe.releaseHeldResponse(); await firstTask.value
        #expect(chat.activeSessionID == b && chat.budgetTracker === trackerB)
        #expect(chat.budgetUsedTokens == 203)
        #expect(await trackerA.budget.usedTokens == 102)
        #expect(chat.applySwitchSession(id: a))
        await chat.syncBudgetStatus(for: a)
        #expect(chat.budgetTracker === trackerA && chat.budgetUsedTokens == 102)
        await probe.holdNextResponse()
        chat.draftText = "owned A cancelled late response"; chat.submitComposer()
        let cancelledTask = try #require(chat.turnTaskForTests(sessionID: a))
        for _ in 0..<200 {
            if await probe.snapshot().count == 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await probe.snapshot().count == 3)
        chat.stopStreamingForSwitch()
        #expect(chat.applySwitchSession(id: b))
        await probe.releaseHeldResponse(); await cancelledTask.value
        await chat.syncBudgetStatus(for: b)
        #expect(chat.budgetTracker === trackerB && chat.budgetUsedTokens == 203)
        #expect(await trackerA.budget.usedTokens == 102)
        #expect(await trackerA.pendingRequestCount == 0)
        #expect(await trackerB.pendingRequestCount == 0)
    }

    private func settleActiveOwner663(_ chat: ChatStore, session: UUID) async throws {
        let task = try #require(chat.turnTaskForTests(sessionID: session))
        await task.value
        #expect(chat.activeSessionID == session && !chat.isActiveSessionGenerating)
    }

    @Test func sameSessionLiveTokenLimitPreservesActualChargesBlocksThenUnlimits() async throws {
        let directory = try root()
        let chat = try chat(root: directory)
        defer { chat.stopAllStreamingForSafety() }
        chat.newSession()
        let sessionID = try #require(chat.activeSessionID)
        let skills = SkillStore(skillsRoot: directory.appendingPathComponent("skills"))
        chat.agentEngine = AgentLoopChatEngine(requestBudget: chat.budgetTracker,
            composerPolicyFacts: chat.composerPolicyFacts)
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(turn: turn,
                skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        let probe = ContextSourcesProbe663()
        chat.streamingProviderOverride = ContextSourcesProvider663(probe: probe)
        chat.draftText = "owned initial cumulative usage"
        chat.submitComposer()
        try await settle(chat)
        let tracker = chat.budgetTracker
        let original = await tracker.budget
        let requestCount = await probe.snapshot().count
        #expect(original.usedTokens > 1 && requestCount > 0)
        chat.setTokenBudgetLimit(1, unlimited: false)
        chat.draftText = "must not enter another Provider request"
        chat.submitComposer()
        try await settle(chat)
        #expect(chat.activeSessionID == sessionID && chat.budgetTracker === tracker)
        #expect(await probe.snapshot().count == requestCount)
        #expect(await tracker.budget.usedTokens == original.usedTokens)
        #expect(chat.requestBudget.usedTokens == original.usedTokens)
        #expect(chat.budgetIsOverLimit && chat.contextLimitReason != nil)
        chat.setTokenBudgetLimit(1, unlimited: true)
        chat.draftText = "same session after explicit unlimited selection"
        chat.submitComposer()
        try await settle(chat)
        #expect(chat.activeSessionID == sessionID && chat.budgetTracker === tracker)
        #expect(await probe.snapshot().count == requestCount + 1)
        #expect(chat.requestBudget.maxTokensPerSession == nil)
        #expect(chat.requestBudget.usedTokens > original.usedTokens)
        #expect(!chat.budgetIsOverLimit)
        #expect(ChatStore.tokenUsageLabel(used: chat.budgetUsedTokens, cap: chat.budgetCapTokens).contains("无上限"))
        // Coalesced settings and a session boundary cannot publish the prior quota.
        chat.setTokenBudgetLimit(11, unlimited: false)
        chat.setTokenBudgetLimit(23, unlimited: false)
        chat.newSession()
        let newTracker = chat.budgetTracker
        chat.draftText = "owned new session uses latest finite selection"
        chat.submitComposer()
        try await settle(chat)
        #expect(chat.activeSessionID != sessionID && newTracker !== tracker)
        #expect(chat.requestBudget.maxTokensPerSession == 23)
        #expect(await newTracker.budget.maxTokensPerSession == 23)
        #expect(await newTracker.budget.usedTokens == chat.requestBudget.usedTokens)
    }

    @Test func explicitUnlimitedPersistenceNeverTreatsInvalidLegacyNumbersAsUnbounded() throws {
        for oldValue in [0, -7, 100000] {
            let old = try JSONSerialization.data(withJSONObject: ["maxTokensPerSession": oldValue])
            let decoded = try JSONDecoder().decode(AgentSettings.self, from: old)
            #expect(!decoded.tokenBudgetUnlimited)
            // 已保存值恰好等于旧默认 10 万的，迁移到新默认 100 万（2026-11-16 用户决定）。
            #expect(decoded.maxTokensPerSession == (oldValue == 100000 ? 1_000_000 : max(1, oldValue)))
        }
        let selected = AgentSettings(maxTokensPerSession: 250, tokenBudgetUnlimited: true)
        let restored = try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(selected))
        #expect(restored.tokenBudgetUnlimited && restored.maxTokensPerSession == 250)
        let field = FieldContextLimitOverride.effectiveTokenLimit(defaultCap: nil,
            environment: ["MINISCANVAS_FIELD_PROFILE":"1", "MINISCANVAS_FIELD_CONTEXT_LIMIT_TOKENS":"3000"],
            arguments: ["--miniscanvas-field-profile"])
        #expect(field == 3000)
        #expect(FieldContextLimitOverride.effectiveTokenLimit(defaultCap: nil, environment: [:], arguments: []) == nil)
    }

    @Test func failedOptionalMemoryReadKeepsSourceUnknownRatherThanClaimingNone() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = MemoryStore(directory: directory)
        let facts = directory.appendingPathComponent("memory/facts.json")
        try FileManager.default.createDirectory(at: facts.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{invalid owned facts".utf8).write(to: facts)
        let scope = MemoryScope(sessionID: UUID().uuidString, projectID: "owned-source-project")
        let injector = MemoryInjector(store: memory)
        // The real optional reader returns a failure result without throwing.
        let failed = try injector.optionalInjection(base: "", userMessage: "owned-source", context: MemoryInjectionContext(scope: scope))
        #expect(failed.readFailed)
        #expect(failed.prompt.isEmpty)
        let prepared = try #require(ChatTurnPromptPreprocessor.prepare(.init(
            basePrompt: "owned base", userMessage: "owned-source", memoryEnabled: true,
            memoryInjector: injector, memoryScope: scope, skillInjector: nil,
            legacySkillResult: SkillInjectionResult(fragment: nil, receipts: []),
            pickerCatalog: [], steers: [], intentText: "owned-source")))
        #expect(prepared.memoryReadFailed)
        #expect(prepared.memorySourceCount == nil)
        #expect(prepared.systemPrompt == "owned base")
    }

    @Test func requestProjectionIsSingleAndUsagePairIsAwaitedForCompleteAndStream() async throws {
        let projectionCalls = OSAllocatedUnfairLock(initialState: 0)
        let observed = OSAllocatedUnfairLock(initialState: [(String, Int, Int?)]())
        let probe = ContextSourcesProbe663()
        let base = ContextSourcesProvider663(probe: probe)
        var wrapper = BudgetRecordingProvider(base: base, onRecorded: { _ in })
        wrapper.messageProjection = { messages in
            projectionCalls.withLock { $0 += 1 }
            return messages + [LLMMessage(role: .assistant, content: "owned projected row")]
        }
        wrapper.requestSources = { delivered, system, tools in
            ChatContextSources(system: .known(system == nil ? 0 : 1, "段提示"),
                memory: .unavailable, skills: .unavailable, mcpTools: .unavailable,
                messages: .known(delivered.count, "条消息"), attachments: .unavailable)
        }
        wrapper.onRequestUsageRecorded = { usage, sources in
            await Task.yield()
            observed.withLock { $0.append(("source", usage.inputTokens, sources.messages.count)) }
        }
        wrapper.onUsageRecorded = { usage in
            observed.withLock { $0.append(("usage", usage.inputTokens, nil)) }
        }
        let messages = [LLMMessage(role: .user, content: "owned original row")]
        _ = try await wrapper.sendMessage(messages: messages, systemPrompt: "owned prompt", maxTokens: 32, temperature: nil)
        _ = try await wrapper.sendMessage(messages: messages, systemPrompt: "owned prompt", tools: [], maxTokens: 32, temperature: nil)
        let stream = try await wrapper.streamAssistantMessage(messages: messages, systemPrompt: "owned prompt",
            tools: [], maxTokens: 32, temperature: nil)
        for try await _ in stream {}
        let requests = await probe.snapshot()
        #expect(projectionCalls.withLock { $0 } == 3)
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.messages.map(\.content) == ["owned original row", "owned projected row"] })
        #expect(requests.allSatisfy { $0.systemPrompt == "owned prompt" })
        let events = observed.withLock { $0 }
        #expect(events.map { $0.0 } == ["source", "usage", "source", "usage", "source", "usage"])
        #expect(events.filter { $0.0 == "source" }.map { $0.1 } == [101, 202, 303])
        #expect(events.filter { $0.0 == "source" }.allSatisfy { $0.2 == 2 })
        let before = events.count
        let cancelledWrapper = wrapper
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try? await cancelledWrapper.sendMessage(messages: messages, systemPrompt: "cancelled", maxTokens: 32, temperature: nil)
        }
        await cancelled.value
        #expect(observed.withLock { $0.count } == before)
        var noUsage = wrapper
        noUsage.base = ContextRequestProvider663(modelID: "no-usage", probe: ContextRequestProbe663())
        _ = try await noUsage.sendMessage(messages: messages, systemPrompt: "no usage", maxTokens: 32, temperature: nil)
        #expect(observed.withLock { $0.count } == before)
        // Nil callback retains the ordinary usage callback, rather than swallowing it.
        var legacy = wrapper
        legacy.onRequestUsageRecorded = nil
        _ = try await legacy.sendMessage(messages: messages, systemPrompt: "legacy", maxTokens: 32, temperature: nil)
        #expect(observed.withLock { $0.last?.0 } == "usage")
        #expect(observed.withLock { $0.count } == before + 1)
    }

    @Test func mcpSourceMetadataComesFromSameCatalogBeforeAppAdditions() async throws {
        let engine = AgentLoopChatEngine(projectSessionDefinitions: [
            AgentToolDefinition(name: "owned-app-extra", description: "Owned App addition", parameters: [:], required: [])
        ])
        let states = OSAllocatedUnfairLock(initialState: [AgentToolCatalogDiscoveryState]())
        let catalog = try await engine.makeTurnToolCatalogWithSources(bridge: ContextSourcesBridge663(),
            settingsAvailable: false, onDiscoveryState: { state in states.withLock { $0.append(state) } },
            speechAvailability: nil)
        #expect(catalog.mcpDefinitions?.map(\.name) == ["mcp_owned_source_echo"])
        #expect(catalog.tools.last?.name == "owned-app-extra")
        #expect(catalog.mcpDefinitions?.contains { $0.name == "owned-app-extra" } == false)
        #expect(states.withLock { $0 } == [.discovering, .succeeded(toolCount: 1)])
        let none = try await engine.makeTurnToolCatalogWithSources(bridge: nil, settingsAvailable: false, speechAvailability: nil)
        #expect(none.mcpDefinitions == [])
        let failed = try await engine.makeTurnToolCatalogWithSources(bridge: ContextSourcesBridge663(fails: true),
            settingsAvailable: false, speechAvailability: nil)
        #expect(failed.mcpDefinitions == nil)
        let answerOnly = try await engine.withAnswerOnlyRegeneration(true).makeTurnToolCatalogWithSources(
            bridge: ContextSourcesBridge663(), settingsAvailable: false, speechAvailability: nil)
        #expect(answerOnly.tools.isEmpty && answerOnly.mcpDefinitions == [])
    }

    @Test func actualToolRequestsPublishSixSourcesWithTheirOwnUsageAndRetainSessionSample() async throws {
        let directory = try root()
        let chat = try chat(root: directory.appendingPathComponent("logs"))
        defer { chat.stopAllStreamingForSafety() }
        chat.newSession(projectID: "source-project", projectName: "Sources", workingDirectory: directory.path)
        let sessionID = try #require(chat.activeSessionID)
        let scope = try #require(chat.activeMemoryScope)
        let memory = MemoryStore(directory: directory.appendingPathComponent("memory"))
        _ = try memory.addFact("source-trigger owned recalled source", memoryScope: scope)
        chat.memoryEnabledProvider = { true }
        chat.memoryInjector = MemoryInjector(store: memory)
        let skills = SkillStore(skillsRoot: directory.appendingPathComponent("skills"))
        _ = try skills.importSkillThroughLifecycle(content: """
        ---
        name: source-trigger
        description: source-trigger
        version: 1
        ---
        OWNED_SOURCE_SKILL_BODY
        """, reason: "owned source fixture", scope: scope,
            approval: SkillApproval(approverID: "source-fixture", scope: scope))
        let bridge = ContextSourcesBridge663()
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: BuiltinToolExecutor(allowedRoot: directory, mcpBridge: bridge),
            requestBudget: chat.budgetTracker, composerPolicyFacts: chat.composerPolicyFacts)
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(turn: turn,
                skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: bridge)
        }
        let probe = ContextSourcesProbe663()
        chat.streamingProviderOverride = ContextSourcesProvider663(probe: probe)
        let attachmentURL = directory.appendingPathComponent("owned.txt")
        try Data("OWNED_TEXT_SOURCE_BODY".utf8).write(to: attachmentURL)
        let imported = try #require(chat.addAttachments(urls: [attachmentURL]).first)
        // Text imports publish through the normal owner-fenced resolution; the
        // task registry is intentionally reserved for unknown ready references.
        for _ in 0..<100 {
            if chat.pendingAttachments.first(where: { $0.id == imported.id })?.status != .pending { break }
            try await Task.sleep(for: .milliseconds(50)) // Existing E11 five-second bound.
        }
        let pending = try #require(chat.pendingAttachments.first { $0.id == imported.id })
        try #require(pending.status == .ready && pending.kind == .text)
        #expect(pending.data == Data("OWNED_TEXT_SOURCE_BODY".utf8))
        chat.draftText = "source-trigger"
        chat.submitComposer()
        try await settle(chat)
        let calls = await probe.snapshot()
        #expect(calls.count == 2)
        #expect(calls.last?.messages.contains { $0.role == .tool } == true)
        #expect(calls.first?.messages.first { $0.role == .user }?.content.contains("OWNED_TEXT_SOURCE_BODY") == true)
        #expect(calls.first?.systemPrompt?.contains("OWNED_SOURCE_SKILL_BODY") == true)
        #expect(calls.first?.systemPrompt?.contains("owned recalled source") == true)
        let sample = try #require(chat.contextOccupancy)
        let sources = try #require(sample.sources)
        #expect(sample.inputTokens == calls.count * 101)
        #expect(sources.system.count == 1)
        #expect(sources.memory.count == 1)
        #expect(sources.skills.count == 1)
        #expect(sources.mcpTools.count == 1)
        #expect(sources.messages.count == calls.last?.messages.count)
        #expect(sources.attachments.count == 1)
        #expect(chat.messages.first { $0.role == .user }?.producerTextAttachmentCount == 1)
        // A later request in the same session replaces both values together.
        chat.draftText = "source-trigger next request"
        chat.submitComposer()
        try await settle(chat)
        let nextCalls = await probe.snapshot()
        let latest = try #require(chat.contextOccupancy)
        #expect(latest.inputTokens == nextCalls.count * 101)
        #expect(latest.sources?.messages.count == nextCalls.last?.messages.count)
        #expect(latest.executionIdentity != sample.executionIdentity)
        chat.newSession()
        #expect(chat.contextOccupancy == nil)
        #expect(chat.applySwitchSession(id: sessionID))
        #expect(chat.contextOccupancy?.inputTokens == latest.inputTokens)
        #expect(chat.contextOccupancy?.sources == latest.sources)
    }

    @Test func freshChatStoreSameSessionDoesNotAliasResetCounterAfterOutputModeChange() async throws {
        let directory = try root()
        let sessionDirectory = directory.appendingPathComponent("sessions")
        let manifestURL = directory.appendingPathComponent("manifests.json")
        let skills = SkillStore(skillsRoot: directory.appendingPathComponent("skills"))
        let probe = ContextRequestProbe663()
        let provider = ContextRequestProvider663(modelID: "ctx663-model-a", probe: probe)
        func configure(_ chat: ChatStore, store: ContextManifestStore) {
            chat.agentEngine = AgentLoopChatEngine(contextManifestStore: store,
                composerPolicyFacts: chat.composerPolicyFacts)
            chat.turnRuntimeSnapshotFactory = { turn, _ in
                ChatTurnRuntimeSnapshot(turn: turn,
                    skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
            }
            chat.streamingProviderOverride = provider
        }
        let firstChat = try chat(root: directory.appendingPathComponent("logs-first"))
        defer { firstChat.stopAllStreamingForSafety() }
        #expect(firstChat.attachPersistence(SessionStore(directory: sessionDirectory),
            badgeStore: SessionBadgeStore(directory: directory.appendingPathComponent("badges-first"))))
        firstChat.newSession()
        let sessionID = try #require(firstChat.activeSessionID)
        let firstStore = try ContextManifestStore(persistenceURL: manifestURL)
        configure(firstChat, store: firstStore)
        firstChat.setOutputMode(.normal)
        firstChat.draftText = "owned ordinary first request 2971"
        firstChat.submitComposer()
        try await settle(firstChat)
        let firstIdentity = try #require(firstChat.executionSnapshot(forSessionID: sessionID)?.executionIdentity)
        let firstTurn = try #require(firstChat.lastComposerSubmissionSnapshot)
        let firstRequests = await probe.snapshot()
        #expect(firstRequests.count == 1)
        let firstIDs = try retainedRunIDs(manifestURL)
        #expect(firstIDs.count == 1)
        let firstID = try #require(firstIDs.first)
        let firstManifest = try #require(firstStore.manifest(runID: firstID))
        let firstReceipt = try #require(firstStore.receipt(runID: firstID))
        #expect(try firstStore.record(manifest: firstManifest, receipt: firstReceipt) == firstReceipt)
        let inspector = try #require(ChatInspectorContextConsumer.capture(store: firstStore,
            sessionID: firstIdentity.turn.sessionID, turnID: firstIdentity.turn.turnID,
            executionIdentity: firstIdentity))
        #expect(inspector.runID == firstID && inspector.snapshot == firstManifest.snapshot)
        let foreignIdentity = AgentExecutionIdentity(turn: AgentTurnIdentity(
            sessionID: "owned-foreign-2971", turnID: firstIdentity.turn.turnID,
            messageID: firstIdentity.turn.messageID), operationID: firstIdentity.operationID,
            attempt: firstIdentity.attempt)
        #expect(ChatInspectorContextConsumer.capture(store: firstStore,
            sessionID: firstIdentity.turn.sessionID, turnID: firstIdentity.turn.turnID,
            executionIdentity: foreignIdentity, explicitRunID: firstID) == nil)
        #expect(ChatInspectorContextConsumer.capture(store: firstStore,
            sessionID: firstIdentity.turn.sessionID, turnID: firstIdentity.turn.turnID + 1,
            executionIdentity: firstIdentity, explicitRunID: firstID) == nil)

        // A real fresh producer reopens the same persisted session. Its local
        // counter starts over, while the previous manifest remains on disk.
        let reopenedSessions = SessionStore(directory: sessionDirectory)
        #expect(reopenedSessions.loadSession(id: sessionID.uuidString) != nil)
        let secondChat = try chat(root: directory.appendingPathComponent("logs-reopened"))
        defer { secondChat.stopAllStreamingForSafety() }
        #expect(secondChat.attachPersistence(reopenedSessions,
            badgeStore: SessionBadgeStore(directory: directory.appendingPathComponent("badges-reopened"))))
        #expect(secondChat.applySwitchSession(id: sessionID))
        #expect(secondChat.executionSnapshot(forSessionID: sessionID)?.executionIdentity == firstIdentity)
        let reopenedStore = try ContextManifestStore(persistenceURL: manifestURL)
        configure(secondChat, store: reopenedStore)
        secondChat.setOutputMode(.concise)
        secondChat.draftText = "owned ordinary reopened request 2971"
        secondChat.submitComposer()
        try await settle(secondChat)
        let secondIdentity = try #require(secondChat.executionSnapshot(forSessionID: sessionID)?.executionIdentity)
        let secondTurn = try #require(secondChat.lastComposerSubmissionSnapshot)
        #expect(secondTurn.sessionID == firstTurn.sessionID)
        #expect(secondTurn.turnID == firstTurn.turnID)
        #expect(secondTurn.messageID != firstTurn.messageID)
        #expect(firstIdentity.turn.messageID == firstTurn.messageID)
        #expect(secondIdentity.turn.messageID == secondTurn.messageID)
        #expect(firstIdentity != secondIdentity)
        let requests = await probe.snapshot()
        #expect(requests.count == 2, "a reset counter must not reject a new canonical message before the provider")
        #expect(secondChat.executionSnapshot(forSessionID: sessionID)?.failureReason == nil)
        let finalIDs = try retainedRunIDs(manifestURL)
        #expect(finalIDs.count == 2)
        #expect(reopenedStore.manifest(runID: firstID) == firstManifest)
        #expect(reopenedStore.receipt(runID: firstID) == firstReceipt)
        let reopenedInspector = try #require(ChatInspectorContextConsumer.capture(store: reopenedStore,
            sessionID: firstIdentity.turn.sessionID, turnID: firstIdentity.turn.turnID,
            executionIdentity: firstIdentity))
        #expect(reopenedInspector.runID == firstID && reopenedInspector.receipt == firstReceipt)
        let secondID = try #require(finalIDs.subtracting(firstIDs).first)
        let secondManifest = try #require(reopenedStore.manifest(runID: secondID))
        let secondReceipt = try #require(reopenedStore.receipt(runID: secondID))
        #expect(firstID.utf8.count <= 256 && secondID.utf8.count <= 256)
        #expect(firstManifest.entries != secondManifest.entries)
        #expect(requests.first?.systemPrompt != requests.last?.systemPrompt)
        let conciseInstruction = try #require(ChatOutputMode.concise.systemPromptInstruction)
        #expect(requests.last?.systemPrompt?.contains(conciseInstruction) == true)
        // The collision guard still rejects changed actual payload under an old
        // key; it does not become a last-writer-wins recovery mechanism.
        let conflicting = ContextManifestReceipt(runID: firstID,
            requestedBudget: secondReceipt.requestedBudget, usedBudget: secondReceipt.usedBudget,
            droppedEntryIDs: secondReceipt.droppedEntryIDs)
        #expect(throws: ContextManifestStoreError.conflictingReceipt) {
            try reopenedStore.record(manifest: secondManifest, receipt: conflicting)
        }
        #expect(reopenedStore.manifest(runID: firstID) == firstManifest)
        print("CTX2971_REOPEN root=\(directory.path) session=\(sessionID) firstTurn=\(firstTurn.turnID) secondTurn=\(secondTurn.turnID) firstMessage=\(firstTurn.messageID) secondMessage=\(secondTurn.messageID) actualRunIDs=\(finalIDs.sorted()) providerCalls=\(requests.count)")
    }

    @Test func legacyExecutionSnapshotDecodesWithoutChangingRetryIdentity() throws {
        let legacy = ChatStore.ExecutionSnapshot(sessionID: UUID(), turnID: 0,
            taskID: "owned-legacy-2971", state: .idle,
            updatedAt: Date(timeIntervalSinceReferenceDate: 2971))
        var oldObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        oldObject.removeValue(forKey: "executionIdentity")
        let oldBytes = try JSONSerialization.data(withJSONObject: oldObject)
        let reopened = try JSONDecoder().decode(ChatStore.ExecutionSnapshot.self, from: oldBytes)
        #expect(reopened.executionIdentity == nil)
        #expect(reopened == legacy)
        #expect(reopened.retryIdentity == legacy.retryIdentity)
    }

    enum ExecutionChange: Sendable, CaseIterable { case session, turn, message, operation, attempt }

    @Test(arguments: ExecutionChange.allCases)
    func generatedManifestSeparatesEveryExecutionIdentityField(_ change: ExecutionChange) async throws {
        let directory = try root()
        let manifestURL = directory.appendingPathComponent("identity-manifests.json")
        let owner = try chat(root: directory.appendingPathComponent("logs"))
        let facts = owner.composerPolicyFacts
        let probe = ContextRequestProbe663()
        let provider = ContextRequestProvider663(modelID: "ctx663-model-a", probe: probe)
        let initial = AgentExecutionIdentity(turn: AgentTurnIdentity(
            sessionID: "owned-2971-session", turnID: 0, messageID: "owned-2971-message"),
            operationID: "owned-2971-operation", attempt: 1)
        let changed = AgentExecutionIdentity(turn: AgentTurnIdentity(
            sessionID: change == .session ? "owned-2971-session-next" : initial.turn.sessionID,
            turnID: change == .turn ? 1 : initial.turn.turnID,
            messageID: change == .message ? "owned-2971-message-next" : initial.turn.messageID),
            operationID: change == .operation ? "owned-2971-operation-next" : initial.operationID,
            attempt: change == .attempt ? 2 : initial.attempt)
        func invoke(_ identity: AgentExecutionIdentity, prompt: String) async throws {
            let store = try ContextManifestStore(persistenceURL: manifestURL)
            let engine = AgentLoopChatEngine(toolExecutor: BuiltinToolExecutor(allowedRoot: directory),
                contextManifestStore: store,
                contextWritebackStorePersistenceURL: directory.appendingPathComponent("writeback.json"),
                toolExecutionFactLedger: try ToolExecutionFactLedger(
                    persistenceURL: directory.appendingPathComponent("facts.json")),
                composerPolicyFacts: facts)
            let composer = ComposerSubmissionSnapshot(mode: .auto, approvalScope: .request, effort: .standard,
                sessionID: identity.turn.sessionID, turnID: identity.turn.turnID,
                taskID: "owned-2971-task", attemptID: "owned-2971-attempt-\(identity.attempt)",
                messageID: identity.turn.messageID, inputDigest: "owned-2971-input",
                workspaceID: facts.workspaceID, createdAt: Date(), policyRevision: facts.revision,
                grantEpoch: facts.grantEpoch, autonomyCeiling: .l3)
            let stream = try await engine.streamReply(provider: provider,
                history: [ChatMessageUI(role: .user, content: "owned identity request")],
                systemPrompt: prompt, maxTokens: 64, conversationID: identity.turn.sessionID,
                authorizedSessionReadSessionID: nil, authorizedSessionReadScope: nil,
                turnID: identity.turn.turnID, composerSnapshot: composer, executionIdentity: identity)
            for try await _ in stream {}
        }
        try await invoke(initial, prompt: "owned initial context")
        let firstIDs = try retainedRunIDs(manifestURL)
        let firstID = try #require(firstIDs.first)
        let firstStore = try ContextManifestStore(persistenceURL: manifestURL)
        let manifest = try #require(firstStore.manifest(runID: firstID))
        let receipt = try #require(firstStore.receipt(runID: firstID))
        #expect(try firstStore.record(manifest: manifest, receipt: receipt) == receipt)
        try await invoke(changed, prompt: "owned changed context")
        let finalIDs = try retainedRunIDs(manifestURL)
        let reopened = try ContextManifestStore(persistenceURL: manifestURL)
        #expect(finalIDs.count == 2 && finalIDs.isSuperset(of: firstIDs))
        #expect(finalIDs.allSatisfy { $0.utf8.count <= 256 })
        #expect(reopened.manifest(runID: firstID) == manifest)
        #expect(reopened.receipt(runID: firstID) == receipt)
        #expect(await probe.snapshot().count == 2)
        print("CTX2971_IDENTITY root=\(directory.path) change=\(change) initial=\(initial) changed=\(changed) actualRunIDs=\(finalIDs.sorted())")
    }

    @Test func explicitCallerRunIDKeepsCollisionRefusalAtTheRealRequestConsumer() async throws {
        let directory = try root()
        let chat = try chat(root: directory.appendingPathComponent("logs"))
        defer { chat.stopAllStreamingForSafety() }
        let sessionID = try #require(chat.activeSessionID)
        let skills = SkillStore(skillsRoot: directory.appendingPathComponent("skills"))
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(turn: turn,
                skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        let url = directory.appendingPathComponent("explicit-manifests.json")
        let store = try ContextManifestStore(persistenceURL: url)
        let cache = ContextOrchestrator()
        let context = snapshot(session: sessionID)
        let probe = ContextRequestProbe663()
        chat.streamingProviderOverride = ContextRequestProvider663(modelID: "ctx663-model-a", probe: probe)
        let callerRunID = "owned-explicit-2971"
        func send(_ text: String) async throws {
            let result = build(cache, snapshot: context, scope: "owned-explicit", text: text)
            chat.agentEngine = AgentLoopChatEngine(contextManifestStore: store,
                contextManifestInput: .init(snapshot: context, result: result, runID: callerRunID),
                composerPolicyFacts: chat.composerPolicyFacts)
            chat.draftText = "owned explicit ordinary input"
            chat.submitComposer()
            try await settle(chat)
        }
        try await send("owned explicit original context")
        let firstTurn = try #require(chat.lastComposerSubmissionSnapshot)
        let first = try #require(store.manifest(runID: callerRunID))
        let receipt = try #require(store.receipt(runID: callerRunID))
        let acceptedIdentity = try #require(chat.executionSnapshot(forSessionID: sessionID)?.executionIdentity)
        let inspector = try #require(ChatInspectorContextConsumer.capture(store: store,
            sessionID: firstTurn.sessionID, turnID: firstTurn.turnID,
            executionIdentity: acceptedIdentity, explicitRunID: callerRunID))
        #expect(inspector.runID == callerRunID && inspector.receipt == receipt)
        #expect(try retainedRunIDs(url) == [callerRunID])
        #expect(await probe.snapshot().count == 1)
        try await send("owned explicit changed context")
        let secondTurn = try #require(chat.lastComposerSubmissionSnapshot)
        #expect(secondTurn.turnID != firstTurn.turnID && secondTurn.messageID != firstTurn.messageID)
        #expect(await probe.snapshot().count == 1, "an explicit caller key must retain its conflict guard")
        #expect(chat.executionSnapshot(forSessionID: sessionID)?.state == .failed)
        let reopened = try ContextManifestStore(persistenceURL: url)
        #expect(reopened.manifest(runID: callerRunID) == first)
        #expect(reopened.receipt(runID: callerRunID) == receipt)
        #expect(try retainedRunIDs(url) == [callerRunID])
        print("CTX2971_EXPLICIT root=\(directory.path) callerRunID=\(callerRunID) firstTurn=\(firstTurn.turnID) rejectedTurn=\(secondTurn.turnID) actualReceipt=\(receipt)")
    }

    /// Selectively extends donor133e2a6f6's real producer hit/miss assertions.
    @Test func realCacheDoesNotAliasSessionScopeOrConfigurationEpoch() {
        let cache = ContextOrchestrator()
        let session = UUID()
        let original = snapshot(session: session)
        let baseline = build(cache, snapshot: original, scope: "project-a")
        let hit = build(cache, snapshot: original, scope: "project-a")
        let otherScope = build(cache, snapshot: original, scope: "project-b")
        let otherSession = build(cache, snapshot: snapshot(session: UUID()), scope: "project-a")
        let otherModel = build(cache, snapshot: snapshot(session: session, model: "ctx663-model-b"), scope: "project-a")
        let otherEpoch = build(cache, snapshot: snapshot(session: session, epoch: "owned-epoch-b"), scope: "project-a")
        #expect(baseline.receipt.cacheDisposition == .miss)
        #expect(hit.receipt.cacheDisposition == .hit)
        #expect([otherScope, otherSession, otherModel, otherEpoch].allSatisfy { $0.receipt.cacheDisposition == .miss })
        #expect(build(cache, snapshot: original, scope: "project-b").receipt.cacheDisposition == .hit)
        #expect(otherScope.manifest?.entries == baseline.manifest?.entries)
        #expect(otherSession.manifest?.snapshotID != baseline.manifest?.snapshotID)
        #expect(otherModel.manifest?.snapshotID != baseline.manifest?.snapshotID)
        #expect(otherEpoch.manifest?.snapshotID != baseline.manifest?.snapshotID)
    }

    @Test(arguments: Drift.allCases)
    func cachedManifestDriftCannotReachTheWrongRealRequest(_ drift: Drift) async throws {
        let directory = try root()
        let chat = try chat(root: directory)
        defer { chat.stopAllStreamingForSafety() }
        // ChatStore requires the existing immutable Skill/MCP turn snapshot
        // before an AgentLoop can consume even an explicit cached manifest.
        let skills = SkillStore(skillsRoot: directory.appendingPathComponent("skills"))
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        let originalSession = try #require(chat.activeSessionID)
        chat.renameSession(id: originalSession, title: "same visible name")
        let cache = ContextOrchestrator()
        let original = snapshot(session: originalSession)
        _ = build(cache, snapshot: original, scope: "project-a", text: "CTX663_SCOPE_A")
        let cached = build(cache, snapshot: original, scope: "project-a", text: "CTX663_SCOPE_A")
        #expect(cached.receipt.cacheDisposition == .hit)
        let probe = ContextRequestProbe663()
        let originalProvider = ContextRequestProvider663(modelID: "ctx663-model-a", probe: probe)
        try await submit(chat, provider: originalProvider, snapshot: original, result: cached, runID: "ctx663-original")
        let baseline = await probe.snapshot()
        #expect(baseline.count == 1)
        #expect(baseline.first?.systemPrompt == "CTX663_SCOPE_A")
        let originalUserIDs = chat.messages.filter { $0.role == .user }.map(\.id)

        let provider: ContextRequestProvider663
        switch drift {
        case .session:
            chat.newSession()
            let second = try #require(chat.activeSessionID)
            #expect(second != originalSession)
            chat.renameSession(id: second, title: "same visible name")
            provider = originalProvider
        case .model:
            provider = ContextRequestProvider663(modelID: "ctx663-model-b", probe: probe)
        }
        try await submit(chat, provider: provider, snapshot: original, result: cached, runID: "ctx663-stale")
        let afterRejected = await probe.snapshot()
        #expect(afterRejected.count == 1, "stale cached context must not cause another provider request")
        let targetSession = try #require(chat.activeSessionID)
        let failed = chat.sessionList.first { $0.id == targetSession }
        #expect(failed?.execution?.state == .failed)
        let retainedSession = try #require(chat.sessions.first { $0.id == originalSession })
        let retainedUserIDs = retainedSession.messages.filter { $0.role == .user }.prefix(originalUserIDs.count).map(\.id)
        #expect(retainedUserIDs == originalUserIDs)

        let fresh = snapshot(session: targetSession, model: provider.model.id)
        let rebuilt = build(cache, snapshot: fresh, scope: "project-b", text: "CTX663_SCOPE_B")
        #expect(rebuilt.receipt.cacheDisposition == .miss)
        try await submit(chat, provider: provider, snapshot: fresh, result: rebuilt, runID: "ctx663-fresh")
        let requests = await probe.snapshot()
        #expect(requests.count == 2)
        #expect(requests.last?.systemPrompt == "CTX663_SCOPE_B")
        #expect(requests.last?.modelID == provider.model.id)
        #expect(requests.last?.messages.last { $0.role == .user }?.content == "owned context request")
    }

    @Test func sameSessionProjectChangeRebuildsCanonicalSkillContextBeforeRequest() async throws {
        let root = try root()
        let chat = try chat(root: root.appendingPathComponent("logs"))
        defer { chat.stopAllStreamingForSafety() }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        #expect(chat.attachPersistence(sessions, badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        chat.newSession(projectID: "project-a", projectName: "same name", workingDirectory: root.path)
        let sessionID = try #require(chat.activeSessionID)
        if var existing = sessions.loadSession(id: sessionID.uuidString) {
            existing.projectID = "project-a"
            try sessions.updateSession(existing)
        } else {
            _ = try sessions.createSession(id: sessionID.uuidString, projectID: "project-a")
        }
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        func importSkill(project: String, name: String, body: String) throws -> String {
            let scope = MemoryScope(sessionID: sessionID.uuidString, projectID: project)
            return try skills.importSkillThroughLifecycle(content: """
            ---
            name: \(name)
            description: owned context trigger
            version: 1
            ---
            \(body)
            """, reason: "owned ctx663 fixture", scope: scope,
            approval: SkillApproval(approverID: "owned-ctx663", scope: scope)).skill.id
        }
        let a = try importSkill(project: "project-a", name: "ctx663a", body: "CTX663_CANONICAL_A")
        let b = try importSkill(project: "project-b", name: "ctx663b", body: "CTX663_CANONICAL_B")
        let settingsOwner = contextSettingsOwner663(root: root, sessions: sessions,
            skills: skills, defaults: chat.preferencesDefaults, log: chat.logManager)
        defer { withExtendedLifetime(settingsOwner) {} }
        #expect(SettingsCenter.active === settingsOwner)
        let manifests = try ContextManifestStore(persistenceURL: root.appendingPathComponent("context-manifests.json"))
        chat.agentEngine = AgentLoopChatEngine(contextManifestStore: manifests,
            chatRuntimeDependencies: .init(sessionStore: sessions,
                memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
                skillStore: skills, soulStore: SoulStore(directory: root.appendingPathComponent("soul"))),
            composerPolicyFacts: chat.composerPolicyFacts)
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        let probe = ContextRequestProbe663()
        chat.streamingProviderOverride = ContextRequestProvider663(modelID: "ctx663-model-a", probe: probe)
        chat.draftText = "ctx663a ctx663b owned context trigger"
        chat.submitComposer()
        try await settle(chat)
        let firstTurn = try #require(chat.lastComposerSubmissionSnapshot)
        let first = try #require(manifests.manifest(runID: try AgentLoopChatEngine.generatedContextManifestRunID(for: AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: firstTurn.sessionID, turnID: firstTurn.turnID, messageID: firstTurn.messageID), operationID: "chat:\(firstTurn.sessionID):\(firstTurn.turnID):\(firstTurn.messageID)", attempt: 1))))
        #expect(first.snapshot.sessionID == sessionID.uuidString)
        #expect(first.snapshot.skillIdentifiers == [a])
        let firstRequests = await probe.snapshot()
        #expect(firstRequests.count == 1)
        #expect(firstRequests.last?.systemPrompt?.contains("CTX663_CANONICAL_A") == true)
        #expect(firstRequests.last?.systemPrompt?.contains("CTX663_CANONICAL_B") == false)

        chat.setProject(.init(id: "project-b", name: "same name", workingDirectory: root.path), forSession: sessionID)
        var moved = try #require(sessions.loadSession(id: sessionID.uuidString))
        moved.projectID = "project-b"
        try sessions.updateSession(moved)
        chat.draftText = "ctx663a ctx663b owned context trigger"
        chat.submitComposer()
        try await settle(chat)
        let secondTurn = try #require(chat.lastComposerSubmissionSnapshot)
        let second = try #require(manifests.manifest(runID: try AgentLoopChatEngine.generatedContextManifestRunID(for: AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: secondTurn.sessionID, turnID: secondTurn.turnID, messageID: secondTurn.messageID), operationID: "chat:\(secondTurn.sessionID):\(secondTurn.turnID):\(secondTurn.messageID)", attempt: 1))))
        #expect(second.snapshot.sessionID == sessionID.uuidString)
        #expect(second.snapshot.skillIdentifiers == [b])
        #expect(second.snapshot.snapshotID != first.snapshot.snapshotID)
        let requests = await probe.snapshot()
        #expect(requests.count == 2)
        #expect(requests.last?.systemPrompt?.contains("CTX663_CANONICAL_B") == true)
        #expect(requests.last?.systemPrompt?.contains("CTX663_CANONICAL_A") == false)
    }
}

private actor ContextRequestProbe663 {
    struct Request: Sendable {
        let modelID: String
        let systemPrompt: String?
        let messages: [LLMMessage]
    }
    private var requests: [Request] = []
    func record(modelID: String, systemPrompt: String?, messages: [LLMMessage]) {
        requests.append(Request(modelID: modelID, systemPrompt: systemPrompt, messages: messages))
    }
    func snapshot() -> [Request] { requests }
}

private struct ContextRequestProvider663: LLMProvider {
    let name = "ctx663-provider"
    var model: LLMModel
    let capabilities: Set<ProviderCapability> = [.tools]
    let probe: ContextRequestProbe663
    init(modelID: String, probe: ContextRequestProbe663) {
        model = LLMModel(id: modelID, displayName: "Owned context", provider: "ctx663-provider")
        self.probe = probe
    }
    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        await probe.record(modelID: model.id, systemPrompt: systemPrompt, messages: messages)
        return LLMResponse(text: "owned ctx663 response", stopReason: "stop", usage: nil)
    }
    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
            maxTokens: maxTokens, temperature: temperature)
    }
    nonisolated(nonsending) func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await probe.record(modelID: model.id, systemPrompt: systemPrompt, messages: messages)
        return AsyncThrowingStream { c in
            c.yield(.text("owned ctx663 response")); c.yield(.finished(stopReason: "stop")); c.finish()
        }
    }
}


/// Actual Bridge composition and normal submit path, with only owned files
/// and the built-in offline Provider. No window, external API or credentials.
@Suite("PERF06 real Bridge skill preparation at AgentLoop", .serialized)
@MainActor
struct BridgeSkillPreparation709Tests {
    enum Drift: Sendable, CaseIterable { case cancel, revision, permissionABA, sessionSwitch, replacedTurn, sharedRevocation }
    @MainActor
    private struct Fixture {
        let root: URL
        let bridge: BridgeStore
        let skills: SkillStore
        let probe: BridgeSkillRead709Probe
        let skillID: String
        let settingsOwner: SettingsCenter // Retain the canonical owner through the real task terminal.
        var chat: ChatStore { bridge.chat }
    }
    private func fixture() throws -> Fixture {
        let formal = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let root = URL(fileURLWithPath: formal).appendingPathComponent("BridgeSkill709-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let probe = BridgeSkillRead709Probe()
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"),
            filesystemAccessObserver: { probe.observe($0) })
        let defaults = try #require(UserDefaults(suiteName: "BridgeSkill709-\(UUID().uuidString)"))
        let manifests = try ContextManifestStore(persistenceURL: root.appendingPathComponent("manifests.json"))
        let bridge = BridgeStore(preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            canvasRuntimeState: .disabled, contextManifestStore: manifests,
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            canvasFeatureLane: .phase3NonCanvas)
        bridge.attachProductionServices(fileAccessAllowedRoot: root,
            fileAccessDeniedRoots: [], sessionDirectory: root.appendingPathComponent("sessions"),
            skillStore: skills, canvasRuntimeState: .disabled,
            externalRunners: [:], externalNetworkAllowed: false)
        let projectID = "owned-project709"
        bridge.chat.newSession(projectID: projectID, projectName: "Owned preprocessing",
                               workingDirectory: root.path)
        let sessionID = try #require(bridge.chat.activeSessionID)
        let scope = MemoryScope(sessionID: sessionID.uuidString, projectID: projectID)
        let imported = try skills.importSkillThroughLifecycle(content: """
        ---
        name: owned-preprocess709
        description: owned preprocess709 trigger
        version: 1
        ---
        PERF709_FROZEN_SKILL_BODY
        """, reason: "owned normal canonical runtime preparation", scope: scope,
            approval: SkillApproval(approverID: "owned-preprocess709", scope: scope))
        let skill = imported.skill
        let reference = skills.skillsRoot.appendingPathComponent("\(skill.id)/references/owned.md")
        try FileManager.default.createDirectory(at: reference.deletingLastPathComponent(), withIntermediateDirectories: true)
        try String(repeating: "owned reference709\n", count: 8192).write(to: reference, atomically: true, encoding: .utf8)
        #expect(bridge.chat.agentEngine is AgentLoopChatEngine)
        #expect(bridge.chat.sessionStore != nil)
        let settingsOwner = contextSettingsOwner663(root: root,
            sessions: try #require(bridge.chat.sessionStore), skills: skills,
            defaults: defaults, log: bridge.chat.logManager)
        #expect(SettingsCenter.active === settingsOwner)
        #expect(bridge.isSafetyFeatureEnabled(.userSkills))
        probe.reset()
        return Fixture(root: root, bridge: bridge, skills: skills, probe: probe, skillID: skill.id, settingsOwner: settingsOwner)
    }
    private func submit(_ f: Fixture, text: String = "owned preprocess709 trigger") throws
        -> (session: UUID, snapshot: ComposerSubmissionSnapshot, task: Task<Void, Never>) {
        let session = try #require(f.chat.activeSessionID)
        f.chat.draftText = text
        f.chat.submitComposer()
        return (session, try #require(f.chat.lastComposerSubmissionSnapshot),
            try #require(f.chat.turnTaskForTests(sessionID: session)))
    }
    private func manifest(_ f: Fixture, _ turn: ComposerSubmissionSnapshot) throws -> ContextManifest? {
        f.bridge.contextManifestStore.manifest(runID: try AgentLoopChatEngine.generatedContextManifestRunID(for: AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: turn.sessionID, turnID: turn.turnID, messageID: turn.messageID), operationID: "chat:\(turn.sessionID):\(turn.turnID):\(turn.messageID)", attempt: 1)))
    }
    private func waitForRead(_ probe: BridgeSkillRead709Probe) async throws {
        for _ in 0..<200 {
            if probe.entered { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(probe.entered, "real Bridge worker never reached the owned payload read")
    }
    private func assertConsumed(_ f: Fixture, _ turn: ComposerSubmissionSnapshot) throws {
        let value = try #require(try manifest(f, turn))
        #expect(value.snapshot.sessionID == turn.sessionID)
        #expect(value.snapshot.skillIdentifiers == [f.skillID])
        #expect(value.entries.contains { $0.identifier == "system-prompt" && !$0.contentHash.isEmpty && $0.required })
        #expect(f.bridge.providerRuntimeObservations.count == 1)
        #expect(f.bridge.providerRuntimeObservations.first?.servedProviderID == "Mock")
        let persisted = try #require(f.chat.sessionStore?.loadSession(id: turn.sessionID))
        #expect(persisted.messages.contains { $0.role == .assistant && $0.content.contains("收到：owned preprocess709 trigger") })
        // Read the actual persisted snapshot afresh, not merely its live mirror.
        let reopened = try ContextManifestStore(persistenceURL: f.root.appendingPathComponent("manifests.json"))
        #expect(reopened.manifest(runID: try AgentLoopChatEngine.generatedContextManifestRunID(for: AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: turn.sessionID, turnID: turn.turnID, messageID: turn.messageID), operationID: "chat:\(turn.sessionID):\(turn.turnID):\(turn.messageID)", attempt: 1))) == value)
    }

    @Test func normalBridgeFactoryWorkerFeedsRealAgentLoopProviderAndPersistedSnapshot() async throws {
        let f = try fixture()
        defer { f.probe.release(); f.chat.stopAllStreamingForSafety() }
        let turn = try submit(f)
        // Synchronous turn capture must not have read the payload before submit
        // returns to the UI actor. The actual worker may already be running.
        #expect(f.probe.mainReads == 0)
        await turn.task.value
        #expect(f.probe.reads == 4) // SKILL + reference + shared before/after
        #expect(f.probe.mainReads == 0)
        try assertConsumed(f, turn.snapshot)
        let receipt = try #require(f.chat.lastSkillInjectionReceipts.first)
        #expect(receipt.skillID == f.skillID)
        #expect(receipt.omittedReason == nil)
        #expect(receipt.contentHash == f.skills.lifecycleReceipt(for: f.skillID)?.contentHash)
        #expect(!f.chat.isStreaming)
    }

    @Test(arguments: Drift.allCases)
    func realPausedReadCannotPublishStaleAuthorityOrCrossSession(_ drift: Drift) async throws {
        let f = try fixture()
        defer { f.probe.release(); f.chat.stopAllStreamingForSafety() }
        f.probe.arm()
        let original = try submit(f)
        try await waitForRead(f.probe)
        #expect(f.probe.mainReads == 0)
        #expect(f.bridge.providerRuntimeObservations.isEmpty)
        #expect(try manifest(f, original.snapshot) == nil)
        var replacement: (session: UUID, snapshot: ComposerSubmissionSnapshot, task: Task<Void, Never>)?
        var protectedSession: UUID?
        var protectedMessages: [ChatMessageUI]?
        switch drift {
        case .cancel:
            f.chat.stopStreaming()
        case .revision:
            let messages = try #require(f.chat.messages(forSession: original.session))
            #expect(f.chat.setMessages(messages, forSession: original.session))
        case .permissionABA:
            f.skills.setEnabled(f.skillID, enabled: false)
            f.skills.setEnabled(f.skillID, enabled: true)
        case .sessionSwitch:
            // F3 permits the old session's frozen turn to finish. It must not
            // replace the newly selected session's draft, transcript or scope.
            f.chat.newSession()
            let selectedSession: UUID = try #require(f.chat.activeSessionID)
            protectedSession = selectedSession
            f.chat.draftText = "new session draft709"
            protectedMessages = f.chat.messages
        case .replacedTurn:
            f.chat.stopStreaming()
            replacement = try submit(f)
        case .sharedRevocation:
            try JSONEncoder().encode(["app:\(f.skillID)": false]).write(
                to: f.root.appendingPathComponent("skills-enabled.json"), options: .atomic)
        }
        f.probe.release()
        // These are the real production Task handles captured before stop.
        // A cleared isStreaming flag cannot stand in for late result completion.
        await original.task.value
        if let replacement { await replacement.task.value }
        switch drift {
        case .sessionSwitch:
            try assertConsumed(f, original.snapshot)
            #expect(f.chat.activeSessionID == protectedSession)
            #expect(f.chat.draftText == "new session draft709")
            #expect(f.chat.messages == protectedMessages)
        case .replacedTurn:
            let replacement = try #require(replacement)
            #expect(replacement.snapshot.turnID != original.snapshot.turnID)
            #expect(try manifest(f, original.snapshot) == nil)
            try assertConsumed(f, replacement.snapshot)
            #expect(!f.chat.isStreaming)
        default:
            #expect(f.bridge.providerRuntimeObservations.isEmpty)
            #expect(try manifest(f, original.snapshot) == nil)
            #expect(!f.chat.isStreaming)
            let persisted = try #require(f.chat.sessionStore?.loadSession(id: original.snapshot.sessionID))
            #expect(!persisted.messages.contains { $0.role == .assistant && $0.content.contains("收到：owned preprocess709 trigger") })
        }
    }
}

private final class BridgeSkillRead709Probe: @unchecked Sendable {
    private let lock = NSLock()
    private let resumeRead = DispatchSemaphore(value: 0)
    private var armed = false
    private var didEnter = false
    private var skippedReads = 1
    private var readCount = 0
    private var mainReadCount = 0
    var entered: Bool { lock.withLock { didEnter } }
    var reads: Int { lock.withLock { readCount } }
    var mainReads: Int { lock.withLock { mainReadCount } }
    func reset() { lock.withLock { readCount = 0; mainReadCount = 0 } }
    func arm() { lock.withLock { armed = true } }
    func release() { resumeRead.signal() }
    func observe(_ access: SkillStoreFilesystemAccess) {
        guard case .fileRead = access else { return }
        let isMain = Thread.isMainThread // synchronous at the real primitive
        let hold = lock.withLock {
            readCount += 1; if isMain { mainReadCount += 1 }
            guard armed, !didEnter else { return false }
            if skippedReads > 0 { skippedReads -= 1; return false }
            didEnter = true; return true
        }
        if hold, !isMain { resumeRead.wait() }
    }
}

/// Owned transport; production ChatStore, prompt preprocessing, catalog and AgentLoop
/// still select/project the actual two requests and consume their tool result.
private actor ContextSourcesProbe663 {
    struct Request: Sendable {
        let messages: [LLMMessage]
        let systemPrompt: String?
        let tools: [AgentToolDefinition]
    }
    private var requests: [Request] = []
    private let toolOnFirstCall: Bool
    private var shouldHoldNextResponse = false
    private var heldResponse: CheckedContinuation<Void, Never>?
    init(toolOnFirstCall: Bool = true) { self.toolOnFirstCall = toolOnFirstCall }
    func holdNextResponse() { shouldHoldNextResponse = true }
    func releaseHeldResponse() { heldResponse?.resume(); heldResponse = nil }
    func reply(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition]) async -> LLMResponse {
        requests.append(Request(messages: messages, systemPrompt: systemPrompt, tools: tools))
        let calls = requests.count
        if shouldHoldNextResponse {
            shouldHoldNextResponse = false
            await withCheckedContinuation { heldResponse = $0 }
        }
        let invokesTool = toolOnFirstCall && calls == 1
        return LLMResponse(text: invokesTool ? "" : "owned completed request", stopReason: invokesTool ? "tool_calls" : "stop",
            // Mirror native parseChatCompletionsUsage with explicit cached_tokens: 0:
            // cacheHitInputTokens carries full prompt input, not a second cache charge.
            usage: LLMUsage(inputTokens: calls * 101, outputTokens: 1,
                cacheReadInputTokens: 0, cacheHitInputTokens: calls * 101),
            toolCalls: invokesTool ? [LLMToolCall(id: "owned-source-tool", name: "mcp_owned_source_echo",
                rawArguments: "{}", arguments: [:])] : [])
    }
    func snapshot() -> [Request] { requests }
}

private struct ContextSourcesProvider663: AssistantStreamingLLMProvider {
    let name = "ctx-source"
    var model = LLMModel(id: "ctx-source-model", displayName: "Owned sources", provider: "ctx-source", contextWindow: 4096)
    let capabilities: Set<ProviderCapability> = [.tools, .streaming]
    let probe: ContextSourcesProbe663
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        await probe.reply(messages: messages, systemPrompt: systemPrompt, tools: [])
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        await probe.reply(messages: messages, systemPrompt: systemPrompt, tools: tools)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let response = await probe.reply(messages: messages, systemPrompt: systemPrompt, tools: [])
        return AsyncThrowingStream { continuation in
            if let usage = response.usage { continuation.yield(.usage(usage)) }
            continuation.yield(.text(response.text)); continuation.finish()
        }
    }
    func streamAssistantMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        let response = await probe.reply(messages: messages, systemPrompt: systemPrompt, tools: tools)
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed(response)); continuation.finish()
        }
    }
}

private struct ContextSourcesBridge663: MCPToolBridge {
    var fails = false
    func mcpBoundTools() async throws -> [MCPBoundTool] {
        if fails { throw MCPClientError.toolNotFound("owned-source") }
        return [MCPBoundTool(fullName: "mcp_owned_source_echo", serverID: "owned-source",
            tool: MCPTool(name: "echo", description: "Owned source echo", inputSchema: .object([
                "type": .string("object"), "properties": .object([:])])))]
    }
    func callMCPTool(fullName: String, arguments: [String: Any]?) async throws -> String { "owned source tool result" }
}
