import Foundation
import CryptoKit
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Reuses the existing detached prompt-preparation seam. It pauses after
/// ChatStore has captured its turn facts, before any model request is made.
private final class PersonaPreparationGate460: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    var isPaused: Bool { lock.withLock { continuation != nil } }

    func wait() async {
        await withCheckedContinuation { next in
            let resumeImmediately = lock.withLock {
                if released { return true }
                continuation = next
                return false
            }
            if resumeImmediately { next.resume() }
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

/// Observes requests from the production AgentLoop; it does not assemble
/// prompts, supply an engine, or perform network requests.
private final class PersonaRequestProvider460: LLMProvider, @unchecked Sendable {
    struct Request: Sendable {
        let messages: [LLMMessage]
        let systemPrompt: String?
    }
    let name = "persona460-local"
    var model = LLMModel(id: "persona460-model", displayName: "Persona 460", provider: "persona460-local")
    var capabilities: Set<ProviderCapability> { [.tools] }
    private let lock = NSLock()
    private var captured: [Request] = []
    private var streams = 0
    var requests: [Request] { lock.withLock { captured } }
    var streamCallCount: Int { lock.withLock { streams } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { captured.append(Request(messages: messages, systemPrompt: systemPrompt)) }
        return LLMResponse(text: "460 synthetic completion", stopReason: "stop", usage: nil)
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

private final class PersonaToolExecutor460: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var executions = 0
    var count: Int { lock.withLock { executions } }
    func execute(name: String, input: [String: Any]) async throws -> String {
        lock.withLock { executions += 1 }
        throw NSError(domain: "Persona460.unexpectedTool", code: 1)
    }
}

@Suite("D-MEMORY-11 persisted persona across actual ordinary requests", .serialized)
@MainActor
struct PersonaSoulNextRequest460Tests {
    private func center(root: URL, defaults: UserDefaults, sessions: SessionStore,
                        memory: MemoryStore, skills: SkillStore, log: LogManager,
                        readiness: ProviderReadinessStore) -> SettingsCenter {
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        return SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: memory,
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: sessions, logManager: log,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp.json"), keychain: keychain),
            skillStore: skills, usageStore: UsageStore(domain: .suite("persona460-" + root.lastPathComponent)),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock, providerReadinessStore: readiness
        )
    }

    private func waitForPause(_ gate: PersonaPreparationGate460) async throws {
        for _ in 0..<300 {
            if gate.isPaused { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "Persona460.missingFrozenBoundary", code: 1)
    }

    private func waitForReply(_ chat: ChatStore, provider: PersonaRequestProvider460,
                              count: Int) async throws {
        for _ in 0..<300 {
            if !chat.isStreaming && provider.requests.count == count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "Persona460.incompleteRealTurn", code: count,
            userInfo: [NSLocalizedDescriptionKey: "actual calls=\(provider.requests.count), streaming=\(chat.isStreaming), last=\(chat.messages.last?.content ?? "<none>"), feedback=\(chat.pastedTextActionFeedback ?? "<none>")"])
    }

    @Test(arguments: [false, true])
    func persistedToggleLeavesFrozenRequestUntouchedAndChangesNextActualRequest(initiallyEnabled: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "persona460-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "persona460-" + root.lastPathComponent
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let sessionID = UUID()
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        _ = try sessions.createSession(id: sessionID.uuidString, title: "owned persona boundary",
            projectID: "project460", projectName: "Owned 460", workingDirectory: root.path)
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let souls = SoulStore(directory: root.appendingPathComponent("souls"))
        try souls.upsert(Soul(id: "owned460", name: "Owned runtime soul",
            systemPrompt: "Synthetic expression preferences only.", isActive: true))
        let soulBytes = try Data(contentsOf: souls.soulsFileURL)
        let log = LogManager(directory: root.appendingPathComponent("logs"))
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let original = center(root: root, defaults: defaults, sessions: sessions,
            memory: memory, skills: skills, log: log, readiness: readiness)
        let firstPersona = Persona(name: "Persona460-Frozen-A", summary: "Original expression only", tone: "concise")
        let nextPersona = Persona(name: "Persona460-Next-B", summary: "Next expression only", tone: "clear")
        original.persona = firstPersona
        original.personaEnabled = initiallyEnabled

        let chat = ChatStore(providerReadinessStore: readiness, preferencesDefaults: defaults, logManager: log)
        defer { chat.stopAllStreamingForSafety() }
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        #expect(chat.attachPersistence(sessions, badgeStore: badges))
        let manager = try #require(chat.sessionManager)
        #expect(manager.store === sessions)
        #expect(manager.badgeStore === badges)
        #expect(manager.store.directory.isFileURL)
        #expect(manager.store.directory.pathComponents == root.appendingPathComponent("sessions").pathComponents)
        #expect(souls.directory.pathComponents == root.appendingPathComponent("souls").pathComponents)
        #expect(chat.applySwitchSession(id: sessionID))
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "persona460-policy", grantEpoch: "persona460-epoch",
            leaseID: "persona460-lease", expiresAt: .distantFuture, autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = .init(mode: .plan, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        chat.configureBudget(from: original.settingsStore.settings.agent)
        let executor = PersonaToolExecutor460()
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        let tasks = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let engine = AgentLoopChatEngine(toolExecutor: executor, taskStore: tasks,
            chatRuntimeDependencies: .init(sessionStore: sessions, memoryStore: memory,
                skillStore: skills, soulStore: souls),
            contextWritebackStorePersistenceURL: root.appendingPathComponent("context.json"),
            toolExecutionFactLedger: ledger, composerPolicyFacts: facts)
        chat.agentEngine = engine.withRequestBudget(chat.budgetTracker)
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        var reverseWrites = 0
        chat.restorePersona(original.persona, enabled: original.personaEnabled)
        chat.onPersonaChanged = { persona, enabled in
            reverseWrites += 1
            original.persona = persona ?? .init()
            original.personaEnabled = enabled
        }
        original.onPersonaSettingsChanged = { [weak chat] persona, enabled in
            chat?.restorePersona(persona, enabled: enabled)
        }
        var sourceReads = 0
        chat.effectiveSettingsSnapshotSource = {
            sourceReads += 1
            return original.bl6EffectiveSettingsSnapshot
        }
        let firstRevision = try #require(original.bl6EffectiveSettingsSnapshot).catalogRevision
        let provider = PersonaRequestProvider460()
        chat.streamingProviderOverride = provider
        let gate = PersonaPreparationGate460()
        defer { gate.release() }
        chat.turnPromptPreprocessPauseForTests = { await gate.wait() }
        chat.draftText = "First ordinary request captures the original persona setting."
        chat.sendDraft()
        try await waitForPause(gate)
        #expect(chat.isStreaming)
        #expect(provider.requests.isEmpty)
        #expect(sourceReads == 1)
        let pausedSession = try #require(sessions.loadSession(id: sessionID.uuidString))
        let sessionURL = sessions.sessionsDirectory.appendingPathComponent(sessionID.uuidString + ".json")
        let pausedBytes = try Data(contentsOf: sessionURL)

        original.persona = nextPersona
        original.personaEnabled = !initiallyEnabled
        #expect(chat.persona == nextPersona)
        #expect(chat.personaEnabled == !initiallyEnabled)
        #expect(reverseWrites == 0)
        #expect(try Data(contentsOf: sessionURL) == pausedBytes)
        let reopened = center(root: root, defaults: defaults, sessions: sessions,
            memory: memory, skills: skills, log: log, readiness: readiness)
        #expect(reopened.settingsStore !== original.settingsStore)
        #expect(reopened.persona == nextPersona)
        #expect(reopened.personaEnabled == !initiallyEnabled)
        let nextRevision = try #require(reopened.bl6EffectiveSettingsSnapshot).catalogRevision
        #expect(nextRevision != firstRevision)
        #expect(sourceReads == 1)
        chat.turnPromptPreprocessPauseForTests = nil
        gate.release()
        try await waitForReply(chat, provider: provider, count: 1)
        let firstRequest = try #require(provider.requests.first)
        let firstPrompt = try #require(firstRequest.systemPrompt)
        #expect(firstPrompt.contains(firstPersona.name) == initiallyEnabled)
        #expect(!firstPrompt.contains(nextPersona.name))
        let completedFirst = try #require(sessions.loadSession(id: sessionID.uuidString))
        #expect(Array(completedFirst.messages.prefix(pausedSession.messages.count)) == pausedSession.messages)

        // Same persisted-startup binding as the App, with the freshly reopened
        // owner now supplying the next ordinary request's canonical snapshot.
        chat.restorePersona(reopened.persona, enabled: reopened.personaEnabled)
        chat.effectiveSettingsSnapshotSource = {
            sourceReads += 1
            return reopened.bl6EffectiveSettingsSnapshot
        }
        let nextText = "Next ordinary request uses the freshly reopened persona setting."
        chat.draftText = nextText
        chat.sendDraft()
        try await waitForReply(chat, provider: provider, count: 2)
        let nextRequest = try #require(provider.requests.last)
        let nextPrompt = try #require(nextRequest.systemPrompt)
        #expect(nextPrompt.contains(nextPersona.name) == !initiallyEnabled)
        #expect(!nextPrompt.contains(firstPersona.name))
        #expect(provider.requests.first?.systemPrompt == firstPrompt)
        #expect(sourceReads == 2)
        #expect(reverseWrites == 0)
        #expect(nextRequest.messages == completedFirst.messages + [LLMMessage(role: .user, content: nextText)])
        let final = try #require(sessions.loadSession(id: sessionID.uuidString))
        #expect(Array(final.messages.prefix(completedFirst.messages.count)) == completedFirst.messages)
        #expect(final.messages.count == completedFirst.messages.count + 2)
        #expect(chat.messages(forSession: sessionID)?.filter { $0.role != .system }.map { $0.asLLMMessage() }
            == final.messages)
        #expect(try Data(contentsOf: souls.soulsFileURL) == soulBytes)
        #expect(chat.composerPolicyFacts == facts)
        #expect(ledger.facts.isEmpty)
        #expect(executor.count == 0)
        #expect(provider.streamCallCount == 0)
        #expect(chat.agentEngine is AgentLoopChatEngine)
    }

    /// Includes every file in the fixture-owned long-term root, including
    /// sidecars. Reject links before reading; a new escaped file is a failure.
    private func ownedMemoryBytes487(_ directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        func normalizedComponents(_ url: URL) throws -> [String] {
            guard url.isFileURL else {
                throw NSError(domain: "Memory487.nonFileURL", code: 1)
            }
            // Foundation may enumerate /var as /private/var. Normalize both
            // sides before deriving full relative names; discard directory hints.
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            return URL(fileURLWithPath: resolved.path, isDirectory: false).pathComponents
        }
        let rootComponents = try normalizedComponents(directory)
        func visit(_ folder: URL) throws {
            let folderValues = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard folderValues.isDirectory == true, folderValues.isSymbolicLink != true else {
                throw NSError(domain: "Memory487.invalidOwnedDirectory", code: 1)
            }
            let folderComponents = try normalizedComponents(folder)
            guard folderComponents.count >= rootComponents.count,
                  Array(folderComponents.prefix(rootComponents.count)) == rootComponents else {
                throw NSError(domain: "Memory487.escapedDirectory", code: 1)
            }
            for file in try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            ) {
                let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else {
                    throw NSError(domain: "Memory487.unexpectedLink", code: 1)
                }
                if values.isDirectory == true {
                    try visit(file)
                } else {
                    guard values.isRegularFile == true else {
                        throw NSError(domain: "Memory487.unexpectedFileKind", code: 1)
                    }
                    let fileComponents = try normalizedComponents(file)
                    guard fileComponents.count > rootComponents.count,
                          Array(fileComponents.prefix(rootComponents.count)) == rootComponents else {
                        throw NSError(domain: "Memory487.escapedFile", code: 1)
                    }
                    let relativeComponents = fileComponents.dropFirst(rootComponents.count)
                    guard relativeComponents.allSatisfy({ !$0.isEmpty && $0 != "/" && $0 != "." && $0 != ".." }) else {
                        throw NSError(domain: "Memory487.invalidRelativeName", code: 1)
                    }
                    let relative = relativeComponents.joined(separator: "/")
                    guard result[relative] == nil else {
                        throw NSError(domain: "Memory487.collidingRelativeName", code: 1)
                    }
                    result[relative] = try Data(contentsOf: file)
                }
            }
        }
        try visit(directory)
        return result
    }

    @Test("D-MEMORY-08 two actual ordinary requests preserve persisted facts, revisions and provenance")
    func ordinaryRequestsDoNotWriteLongTermMemory487() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "memory487-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "memory487-" + root.lastPathComponent
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let id = UUID()
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        _ = try sessions.createSession(id: id.uuidString, title: "owned ordinary memory boundary",
            projectID: "project487", projectName: "Owned 487", workingDirectory: root.path)
        let memoryRoot = root.appendingPathComponent("long-term-memory")
        let memory = MemoryStore(directory: memoryRoot)
        let scope = MemoryScope(sessionID: id.uuidString, projectID: "project487")
        let oldText = "owned487 historical preference blue"
        let activeText = "owned487 active preference blue"
        let first = try memory.addFact(id: "owned487-r1", text: oldText,
            sourceSessionID: id.uuidString, memoryScope: scope,
            sourceProposalID: "owned487-proposal1", sourceRef: "fixture://owned487/source1",
            contentDigest: MemoryStore.contentDigest(for: oldText))
        let second = try memory.appendRevision(to: first.id, id: "owned487-r2", text: activeText,
            sourceSessionID: id.uuidString, memoryScope: scope,
            sourceProposalID: "owned487-proposal2", sourceRef: "fixture://owned487/source2",
            contentDigest: MemoryStore.contentDigest(for: activeText))
        #expect(second.revision == 2)
        #expect(second.supersedesFactID == first.id)
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let souls = SoulStore(directory: root.appendingPathComponent("souls"))
        try souls.upsert(Soul(id: "owned487", name: "Owned runtime dependency",
            systemPrompt: "Synthetic expression only.", isActive: true))
        let log = LogManager(directory: root.appendingPathComponent("logs"))
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let owner = center(root: root, defaults: defaults, sessions: sessions,
            memory: memory, skills: skills, log: log, readiness: readiness)
        owner.memoryEnabled = true
        #expect(owner.memoryStore === memory)
        #expect(owner.memoryProposalConsumer.store === memory)
        let chat = ChatStore(providerReadinessStore: readiness, preferencesDefaults: defaults, logManager: log)
        defer { chat.stopAllStreamingForSafety() }
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        #expect(chat.attachPersistence(sessions, badgeStore: badges))
        let manager = try #require(chat.sessionManager)
        #expect(manager.store === sessions)
        #expect(manager.badgeStore === badges)
        #expect(chat.applySwitchSession(id: id))
        #expect(chat.activeMemoryScope == scope)
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "memory487-policy", grantEpoch: "memory487-epoch",
            leaseID: "memory487-lease", expiresAt: .distantFuture, autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = .init(mode: .plan, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        chat.configureBudget(from: owner.settingsStore.settings.agent)
        // Same App read-only memory composition. No memory command, proposal
        // approval, lifecycle action, or store writer is called after baseline.
        chat.memoryInjector = MemoryInjector(store: memory)
        chat.memoryEnabledProvider = { owner.memoryEnabled }
        #expect(chat.memoryInjector?.store === memory)
        chat.effectiveSettingsSnapshotSource = { owner.bl6EffectiveSettingsSnapshot }
        let executor = PersonaToolExecutor460()
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        let tasks = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let engine = AgentLoopChatEngine(toolExecutor: executor, taskStore: tasks,
            chatRuntimeDependencies: .init(sessionStore: sessions, memoryStore: memory,
                skillStore: skills, soulStore: souls),
            contextWritebackStorePersistenceURL: root.appendingPathComponent("context.json"),
            toolExecutionFactLedger: ledger, composerPolicyFacts: facts)
        chat.agentEngine = engine.withRequestBudget(chat.budgetTracker)
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        let provider = PersonaRequestProvider460()
        chat.streamingProviderOverride = provider
        let factsBefore = try memory.facts()
        #expect(factsBefore.count == 2)
        #expect(factsBefore.first { $0.id == first.id }?.lifecycleState == .superseded)
        #expect(try memory.activeFacts() == [second])
        let receiptsBefore = try memory.lifecycleReceipts()
        let envelopesBefore = try owner.memoryProposalConsumer.envelopes()
        let bytesBefore = try ownedMemoryBytes487(memoryRoot)
        #expect(!bytesBefore.isEmpty)
        #expect(bytesBefore["memory/facts.json"] != nil)
        #expect(memory.fileURL.isFileURL)
        #expect(bytesBefore["memory/facts.json"] == (try Data(contentsOf: memory.fileURL)))
        let initial = try #require(sessions.loadSession(id: id.uuidString))

        for (index, text) in [
            "Discuss the blue preference as ordinary conversation, without saving a memory.",
            "Continue the blue discussion as another ordinary request, without a memory command."
        ].enumerated() {
            let prior = try #require(sessions.loadSession(id: id.uuidString))
            chat.draftText = text
            chat.sendDraft()
            try await waitForReply(chat, provider: provider, count: index + 1)
            let request = try #require(provider.requests.last)
            let prompt = try #require(request.systemPrompt)
            // Proves the actual consumer read this nonempty store. An unused
            // or detached empty MemoryStore cannot satisfy this positive.
            #expect(prompt.contains(activeText))
            #expect(!prompt.contains(oldText))
            #expect(request.messages == prior.messages + [LLMMessage(role: .user, content: text)])
            #expect(try memory.facts() == factsBefore)
            #expect(try memory.activeFacts() == [second])
            #expect(try memory.lifecycleReceipts() == receiptsBefore)
            #expect(try owner.memoryProposalConsumer.envelopes() == envelopesBefore)
            #expect(try ownedMemoryBytes487(memoryRoot) == bytesBefore)
            let completed = try #require(sessions.loadSession(id: id.uuidString))
            #expect(Array(completed.messages.prefix(prior.messages.count)) == prior.messages)
            #expect(completed.messages.count == prior.messages.count + 2)
        }
        let reopened = MemoryStore(directory: memoryRoot)
        #expect(reopened !== memory)
        #expect(try reopened.facts() == factsBefore)
        #expect(try reopened.activeFacts() == [second])
        #expect(try reopened.lifecycleReceipts() == receiptsBefore)
        #expect(try MemoryProposalConsumer(store: reopened).envelopes() == envelopesBefore)
        #expect(try ownedMemoryBytes487(memoryRoot) == bytesBefore)
        let final = try #require(sessions.loadSession(id: id.uuidString))
        #expect(Array(final.messages.prefix(initial.messages.count)) == initial.messages)
        #expect(final.messages.count == initial.messages.count + 4)
        #expect(chat.messages(forSession: id)?.filter { $0.role != .system }.map { $0.asLLMMessage() } == final.messages)
        #expect(chat.composerPolicyFacts == facts)
        #expect(executor.count == 0)
        #expect(ledger.facts.isEmpty)
        #expect(provider.requests.count == 2)
        #expect(provider.streamCallCount == 0)
        #expect(chat.agentEngine is AgentLoopChatEngine)
    }

    @Test("D-MEMORY-05/12 Settings CRUD survives owner reconstruction and reaches actual next requests")
    func settingsCRUDReopenFeedsActualNextRequests496() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "memory496-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "memory496-" + root.lastPathComponent
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let id = UUID()
        let sessionRoot = root.appendingPathComponent("sessions")
        let memoryRoot = root.appendingPathComponent("long-term-memory")
        let sessions = SessionStore(directory: sessionRoot)
        _ = try sessions.createSession(id: id.uuidString, title: "owned settings memory recovery",
            projectID: "project496", projectName: "Owned 496", workingDirectory: root.path)
        let scope = MemoryScope(sessionID: id.uuidString, projectID: "project496")
        let memory = MemoryStore(directory: memoryRoot)
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let souls = SoulStore(directory: root.appendingPathComponent("souls"))
        try souls.upsert(Soul(id: "owned496", name: "Owned runtime dependency",
            systemPrompt: "Synthetic expression only.", isActive: true))
        let log = LogManager(directory: root.appendingPathComponent("logs"))
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let writer = center(root: root, defaults: defaults, sessions: sessions,
            memory: memory, skills: skills, log: log, readiness: readiness)
        _ = try writer.provisionMemoryCandidateSubmission()
        writer.memoryScopeProvider = { scope }
        writer.memoryEnabled = true
        let oldText = "orbit496 old preference"
        let editedText = "orbit496 new preference"
        let deletedText = "deleted496 doomed preference"
        #expect(writer.addMemoryFactResult(deletedText, category: .lesson) == .added)
        #expect(writer.addMemoryFactResult(oldText, category: .userPref) == .added)
        let original = try #require(writer.memoryFacts.first { $0.text == oldText })
        let deleted = try #require(writer.memoryFacts.first { $0.text == deletedText })
        #expect(original.memoryScope == scope)
        #expect(original.sourceSessionID == id.uuidString)
        #expect(original.sourceProposalID != nil)
        #expect(original.sourceRef != nil)
        #expect(original.contentDigest == MemoryStore.contentDigest(for: oldText))
        let provider = PersonaRequestProvider460()
        let initial = try #require(sessions.loadSession(id: id.uuidString))

        for phase in 0..<2 {
            if phase == 1 {
                let edited = try writer.editMemoryFact(id: original.id, newText: editedText)
                #expect(edited.revision == original.revision + 1)
                #expect(edited.supersedesFactID == original.id)
                #expect(edited.sourceSessionID == original.sourceSessionID)
                #expect(edited.memoryScope == scope)
                #expect(edited.category == original.category)
                #expect(edited.sourceProposalID == "user-edit:\(original.id):r\(edited.revision)")
                #expect(edited.sourceRef == "settings://memory/\(original.id)/revision-\(edited.revision)")
                #expect(edited.contentDigest == MemoryStore.contentDigest(for: editedText))
                let preview = try writer.previewMemoryFactDeletion(id: deleted.id)
                let beforeRejectedFacts = try memory.facts()
                let beforeRejectedBytes = try Data(contentsOf: memory.fileURL)
                let beforeRejectedProposals = try writer.memoryProposalConsumer.envelopes()
                #expect(throws: DeletionGateError.firstConfirmationRequired) {
                    try writer.removeMemoryFact(id: deleted.id, intent: preview)
                }
                #expect(try memory.facts() == beforeRejectedFacts)
                #expect(try Data(contentsOf: memory.fileURL) == beforeRejectedBytes)
                #expect(try writer.memoryProposalConsumer.envelopes() == beforeRejectedProposals)
                let confirmed = preview.withFirstConfirmation("我已核对这份精确预览")
                    .withSecondConfirmation("永久删除")
                let receipt = try writer.removeMemoryFact(id: deleted.id, intent: confirmed)
                #expect(receipt.targetID == deleted.id)
                #expect(receipt.operationID == preview.operationID)
                #expect(receipt.affectedCount == 1)
                #expect(try memory.facts().allSatisfy { $0.id != deleted.id })
            }
            let expectedFacts = try memory.facts()
            let expectedActive = try memory.activeFacts()
            let expectedReceipts = try memory.lifecycleReceipts()
            let expectedProposals = try writer.memoryProposalConsumer.envelopes()
            let expectedBytes = try Data(contentsOf: memory.fileURL)
            let activeSessions = phase == 0 ? sessions : SessionStore(directory: sessionRoot)
            let activeMemory = phase == 0 ? memory : MemoryStore(directory: memoryRoot)
            let owner: SettingsCenter
            if phase == 0 {
                owner = writer
            } else {
                owner = center(root: root, defaults: defaults, sessions: activeSessions,
                    memory: activeMemory, skills: skills, log: log, readiness: readiness)
                owner.memoryScopeProvider = { scope }
                #expect(owner.settingsStore !== writer.settingsStore)
                #expect(activeSessions !== sessions)
                #expect(activeMemory !== memory)
                #expect(owner.memoryEnabled)
                owner.reloadStorage()
                // Complete value equality includes source fields, revisions,
                // activation dates, lifecycle state and all historical values.
                #expect(try activeMemory.facts() == expectedFacts)
                #expect(try activeMemory.lifecycleReceipts() == expectedReceipts)
                #expect(try owner.memoryProposalConsumer.envelopes() == expectedProposals)
                #expect(try Data(contentsOf: activeMemory.fileURL) == expectedBytes)
                #expect(expectedFacts.first { $0.id == original.id }?.lifecycleState == .superseded)
                #expect(expectedFacts.allSatisfy { $0.id != deleted.id })
                #expect(expectedActive.count == 1)
                #expect(expectedActive.first?.text == editedText)
            }
            #expect(owner.memoryStore === activeMemory)
            #expect(owner.memoryProposalConsumer.store === activeMemory)
            #expect(owner.memoryFacts == expectedActive)
            #expect(owner.memoryFactTotalCount == expectedFacts.count)
            let chat = ChatStore(providerReadinessStore: readiness, preferencesDefaults: defaults, logManager: log)
            defer { chat.stopAllStreamingForSafety() }
            let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
            #expect(chat.attachPersistence(activeSessions, badgeStore: badges))
            let manager = try #require(chat.sessionManager)
            #expect(manager.store === activeSessions)
            #expect(manager.badgeStore === badges)
            #expect(chat.applySwitchSession(id: id))
            #expect(chat.activeMemoryScope == scope)
            let policy = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
                workspaceID: chat.composerWorkspaceID, revision: "memory496-policy", grantEpoch: "memory496-epoch",
                leaseID: "memory496-lease", expiresAt: .distantFuture, autonomyCeiling: .l3)
            chat.configureComposerPolicy(policy)
            chat.composerPolicySelection = .init(mode: .plan, approvalScope: .request,
                effort: .standard, bypassModeConfirmed: false)
            chat.configureBudget(from: owner.settingsStore.settings.agent)
            chat.memoryInjector = MemoryInjector(store: activeMemory)
            chat.memoryEnabledProvider = { owner.memoryEnabled }
            chat.effectiveSettingsSnapshotSource = { owner.bl6EffectiveSettingsSnapshot }
            let executor = PersonaToolExecutor460()
            let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts-\(phase).json"))
            let tasks = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks-\(phase).json"))
            let engine = AgentLoopChatEngine(toolExecutor: executor, taskStore: tasks,
                chatRuntimeDependencies: .init(sessionStore: activeSessions, memoryStore: activeMemory,
                    skillStore: skills, soulStore: souls),
                contextWritebackStorePersistenceURL: root.appendingPathComponent("context-\(phase).json"),
                toolExecutionFactLedger: ledger, composerPolicyFacts: policy)
            chat.agentEngine = engine.withRequestBudget(chat.budgetTracker)
            chat.turnRuntimeSnapshotFactory = { turn, _ in
                .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
            }
            chat.streamingProviderOverride = provider
            let prior = try #require(activeSessions.loadSession(id: id.uuidString))
            let text = "orbit496 deleted496 ordinary discussion phase \(phase)"
            chat.draftText = text
            chat.sendDraft()
            try await waitForReply(chat, provider: provider, count: phase + 1)
            let request = try #require(provider.requests.last)
            let prompt = try #require(request.systemPrompt)
            #expect(prompt.contains(phase == 0 ? oldText : editedText))
            #expect(prompt.contains(deletedText) == (phase == 0))
            if phase == 1 { #expect(!prompt.contains(oldText)) }
            #expect(request.messages == prior.messages + [LLMMessage(role: .user, content: text)])
            #expect(try activeMemory.facts() == expectedFacts)
            #expect(try activeMemory.activeFacts() == expectedActive)
            #expect(try activeMemory.lifecycleReceipts() == expectedReceipts)
            #expect(try owner.memoryProposalConsumer.envelopes() == expectedProposals)
            #expect(try Data(contentsOf: activeMemory.fileURL) == expectedBytes)
            let completed = try #require(activeSessions.loadSession(id: id.uuidString))
            #expect(Array(completed.messages.prefix(prior.messages.count)) == prior.messages)
            #expect(completed.messages.count == prior.messages.count + 2)
            #expect(chat.messages(forSession: id)?.filter { $0.role != .system }.map { $0.asLLMMessage() } == completed.messages)
            #expect(chat.composerPolicyFacts == policy)
            #expect(executor.count == 0)
            #expect(ledger.facts.isEmpty)
            #expect(chat.agentEngine is AgentLoopChatEngine)
        }
        let final = try #require(sessions.loadSession(id: id.uuidString))
        #expect(Array(final.messages.prefix(initial.messages.count)) == initial.messages)
        #expect(final.messages.count == initial.messages.count + 4)
        #expect(provider.requests.count == 2)
        #expect(provider.streamCallCount == 0)
    }

    @Test("D-MEMORY-11 persisted Soul expression freezes in-flight A and reaches next actual request B")
    func persistedSoulExpressionStaysFrozenAndFeedsNextActualRequest511() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "soul511-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "soul511-" + root.lastPathComponent
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let id = UUID()
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        _ = try sessions.createSession(id: id.uuidString, title: "owned Soul expression boundary",
            projectID: "project511", projectName: "Owned 511", workingDirectory: root.path)
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let souls = SoulStore(directory: root.appendingPathComponent("souls"))
        let firstSoul = Soul(id: "owned511", name: "Soul511-Frozen-A",
            systemPrompt: "Soul511-Expression-A: use concise synthetic descriptions.", isActive: true)
        let nextSoul = Soul(id: firstSoul.id, name: "Soul511-Next-B",
            systemPrompt: "Soul511-Expression-B: use clear synthetic descriptions.", isActive: true)
        try souls.upsert(firstSoul)
        let firstSoulBytes = try Data(contentsOf: souls.soulsFileURL)
        let log = LogManager(directory: root.appendingPathComponent("logs"))
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let owner = center(root: root, defaults: defaults, sessions: sessions,
            memory: memory, skills: skills, log: log, readiness: readiness)
        let persona = Persona(name: "Persona511-Unchanged", summary: "Expression only")
        owner.persona = persona
        owner.personaEnabled = true
        let settingsBefore = owner.settingsStore.settings
        let memoryBefore = try memory.facts()
        let chat = ChatStore(providerReadinessStore: readiness, preferencesDefaults: defaults, logManager: log)
        defer { chat.stopAllStreamingForSafety() }
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        #expect(chat.attachPersistence(sessions, badgeStore: badges))
        let manager = try #require(chat.sessionManager)
        #expect(manager.store === sessions)
        #expect(manager.badgeStore === badges)
        #expect(chat.applySwitchSession(id: id))
        #expect(souls.directory.isFileURL)
        #expect(souls.directory.pathComponents == root.appendingPathComponent("souls").pathComponents)
        let scopeBefore = chat.activeMemoryScope
        let policy = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "soul511-policy", grantEpoch: "soul511-epoch",
            leaseID: "soul511-lease", expiresAt: .distantFuture, autonomyCeiling: .l3)
        chat.configureComposerPolicy(policy)
        chat.composerPolicySelection = .init(mode: .plan, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        chat.configureBudget(from: owner.settingsStore.settings.agent)
        chat.restorePersona(owner.persona, enabled: owner.personaEnabled)
        chat.effectiveSettingsSnapshotSource = { owner.bl6EffectiveSettingsSnapshot }
        let executor = PersonaToolExecutor460()
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        let tasks = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let manifests = try ContextManifestStore(persistenceURL: root.appendingPathComponent("manifests.json"))
        let engine = AgentLoopChatEngine(toolExecutor: executor, taskStore: tasks, contextManifestStore: manifests,
            chatRuntimeDependencies: .init(sessionStore: sessions, memoryStore: memory,
                skillStore: skills, soulStore: souls),
            contextWritebackStorePersistenceURL: root.appendingPathComponent("context.json"),
            toolExecutionFactLedger: ledger, composerPolicyFacts: policy)
        chat.agentEngine = engine.withRequestBudget(chat.budgetTracker)
        #expect((chat.agentEngine as? AgentLoopChatEngine)?.chatRuntimeDependencies?.soulStore === souls)
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        let provider = PersonaRequestProvider460()
        chat.streamingProviderOverride = provider
        let gate = PersonaPreparationGate460()
        defer { gate.release() }
        chat.turnPromptPreprocessPauseForTests = { await gate.wait() }
        let initial = try #require(sessions.loadSession(id: id.uuidString))
        let firstText = "First ordinary request uses the frozen Soul expression."
        chat.draftText = firstText
        chat.sendDraft()
        try await waitForPause(gate)
        #expect(chat.isStreaming)
        #expect(provider.requests.isEmpty)
        let firstIdentity = try #require(chat.activeExecutionIdentity(for: id))
        let paused = try #require(sessions.loadSession(id: id.uuidString))
        let sessionURL = sessions.sessionsDirectory.appendingPathComponent(id.uuidString + ".json")
        let pausedBytes = try Data(contentsOf: sessionURL)

        // Only the existing same-id expression API changes. No new toggle,
        // import, active-id selection, permission or scope producer is involved.
        try souls.upsert(nextSoul)
        let nextSoulBytes = try Data(contentsOf: souls.soulsFileURL)
        #expect(nextSoulBytes != firstSoulBytes)
        let reopened = SoulStore(directory: souls.directory)
        #expect(reopened !== souls)
        #expect(reopened.activeSoul() == nextSoul)
        #expect(reopened.listSouls() == souls.listSouls())
        #expect(try Data(contentsOf: reopened.soulsFileURL) == nextSoulBytes)
        #expect(owner.settingsStore.settings == settingsBefore)
        #expect(try Data(contentsOf: sessionURL) == pausedBytes)
        #expect(chat.composerPolicyFacts == policy)
        #expect(chat.activeMemoryScope == scopeBefore)
        chat.turnPromptPreprocessPauseForTests = nil
        gate.release()
        try await waitForReply(chat, provider: provider, count: 1)
        let firstRequest = try #require(provider.requests.first)
        let firstPrompt = try #require(firstRequest.systemPrompt)
        #expect(firstPrompt.contains(firstSoul.systemPrompt))
        #expect(!firstPrompt.contains(nextSoul.systemPrompt))
        #expect(firstPrompt.contains(persona.name))
        #expect(firstPrompt.contains("人格仅影响表达方式和偏好"))
        #expect(firstPrompt.contains("不授予或扩大工具、文件、网络、MCP、记忆或画布权限"))
        #expect(firstRequest.messages == initial.messages + [LLMMessage(role: .user, content: firstText)])
        let firstRun = try AgentLoopChatEngine.generatedContextManifestRunID(for: firstIdentity)
        let firstManifest = try #require(manifests.manifest(runID: firstRun))
        let firstEntry = try #require(firstManifest.entries.first { $0.identifier == "system-prompt" })
        #expect(firstManifest.snapshot.sessionID == id.uuidString)
        #expect(firstManifest.entries.count == 1)
        #expect(firstEntry.required)
        #expect(firstEntry.contentHash == ContextItem.hash(content: firstPrompt, identifier: firstEntry.identifier))
        let firstReceipt = try #require(manifests.receipt(runID: firstRun))
        #expect(firstReceipt.droppedEntryIDs.isEmpty)
        let completedFirst = try #require(sessions.loadSession(id: id.uuidString))
        #expect(Array(completedFirst.messages.prefix(paused.messages.count)) == paused.messages)
        #expect(completedFirst.messages.count == initial.messages.count + 2)

        let nextText = "Next ordinary request consumes the persisted Soul expression change."
        chat.draftText = nextText
        chat.sendDraft()
        let nextIdentity = try #require(chat.activeExecutionIdentity(for: id))
        try await waitForReply(chat, provider: provider, count: 2)
        let nextRequest = try #require(provider.requests.last)
        let nextPrompt = try #require(nextRequest.systemPrompt)
        #expect(nextPrompt.contains(nextSoul.systemPrompt))
        #expect(!nextPrompt.contains(firstSoul.systemPrompt))
        #expect(nextPrompt.contains(persona.name))
        #expect(provider.requests.first?.systemPrompt == firstPrompt)
        #expect(nextRequest.messages == completedFirst.messages + [LLMMessage(role: .user, content: nextText)])
        let nextRun = try AgentLoopChatEngine.generatedContextManifestRunID(for: nextIdentity)
        #expect(nextRun != firstRun)
        let nextManifest = try #require(manifests.manifest(runID: nextRun))
        let nextEntry = try #require(nextManifest.entries.first { $0.identifier == "system-prompt" })
        #expect(nextManifest.snapshot.sessionID == id.uuidString)
        #expect(nextManifest.entries.count == 1)
        #expect(nextEntry.required)
        #expect(nextEntry.contentHash == ContextItem.hash(content: nextPrompt, identifier: nextEntry.identifier))
        #expect(nextEntry.contentHash != firstEntry.contentHash)
        #expect(manifests.manifest(runID: firstRun) == firstManifest)
        #expect(manifests.receipt(runID: firstRun) == firstReceipt)
        let final = try #require(sessions.loadSession(id: id.uuidString))
        #expect(Array(final.messages.prefix(completedFirst.messages.count)) == completedFirst.messages)
        #expect(final.messages.count == initial.messages.count + 4)
        #expect(chat.messages(forSession: id)?.filter { $0.role != .system }.map { $0.asLLMMessage() } == final.messages)
        #expect(try Data(contentsOf: souls.soulsFileURL) == nextSoulBytes)
        #expect(try memory.facts() == memoryBefore)
        #expect(owner.settingsStore.settings == settingsBefore)
        #expect(chat.composerPolicyFacts == policy)
        #expect(chat.activeMemoryScope == scopeBefore)
        #expect(ledger.facts.isEmpty)
        #expect(executor.count == 0)
        #expect(provider.requests.count == 2)
        #expect(provider.streamCallCount == 0)
        #expect(chat.agentEngine is AgentLoopChatEngine)
    }

    @Test("D-MEMORY-11 retry keeps the admitted Soul while Provider construction is suspended")
    func retryProviderPreparationKeepsAdmittedSoul1796() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "soul1796-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "soul1796-" + root.lastPathComponent
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let id = UUID()
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        _ = try sessions.createSession(id: id.uuidString, title: "owned Soul retry",
            projectID: "project1796", projectName: "Owned 1796", workingDirectory: root.path)
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let souls = SoulStore(directory: root.appendingPathComponent("souls"))
        let firstSoul = Soul(id: "owned1796", name: "Soul1796-A",
            systemPrompt: "Soul1796-expression-A: synthetic first revision.", isActive: true)
        let nextSoul = Soul(id: "owned1796-next", name: "Soul1796-B",
            systemPrompt: "Soul1796-expression-B: synthetic next revision.", isActive: false)
        try souls.upsert(firstSoul)
        try souls.upsert(nextSoul)
        let manifests = try ContextManifestStore(persistenceURL: root.appendingPathComponent("manifests.json"))
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        let tasks = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let chat = ChatStore(preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")))
        defer { chat.stopAllStreamingForSafety() }
        #expect(chat.attachPersistence(sessions,
            badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        #expect(chat.applySwitchSession(id: id))
        let policy = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [],
            allowedWriteRoots: [], workspaceID: chat.composerWorkspaceID,
            revision: "soul1796-policy", grantEpoch: "soul1796-epoch",
            leaseID: "soul1796-lease", expiresAt: .distantFuture, autonomyCeiling: .l3)
        chat.configureComposerPolicy(policy)
        chat.composerPolicySelection = .init(mode: .plan, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        let executor = PersonaToolExecutor460()
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: executor, taskStore: tasks,
            contextManifestStore: manifests,
            chatRuntimeDependencies: .init(sessionStore: sessions, memoryStore: memory,
                skillStore: skills, soulStore: souls),
            contextWritebackStorePersistenceURL: root.appendingPathComponent("context.json"),
            toolExecutionFactLedger: ledger, composerPolicyFacts: policy)
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        let provider = PersonaRequestProvider460()
        chat.streamingProviderOverride = provider
        chat.draftText = "Reference request with Soul A"
        chat.sendDraft()
        try await waitForReply(chat, provider: provider, count: 1)
        let referencePrompt = try #require(provider.requests.first?.systemPrompt)
        #expect(referencePrompt.contains(firstSoul.systemPrompt))

        // A real failed-session retry creates its execution and placeholder
        // before the selected Provider worker resumes. The endpoint is an
        // owned loopback refusal; the durable Context consumer runs first.
        chat.appendUser("Failed request to retry with Soul A")
        chat.markExecutionRunning(sessionID: id, turnID: 7, taskID: "owned-failed-task")
        chat.markExecutionFailed(sessionID: id, reason: "synthetic retry trigger")
        let failed = try #require(chat.sessionList.first?.retryIdentity)
        let record = EnvVarEntry(name: "SYNTHETIC_SOUL_RETRY_1796", value: "owned-fixture-key",
            isSecret: true, valueInKeychain: false, baseURL: "http://127.0.0.1:1",
            modelNames: ["retry-model"], protocolType: .openaiCompatible)
        chat.selectedCustomProvider = record
        chat.selectedModelID = "retry-model"
        chat.streamingProviderOverride = nil
        let gate = PersonaPreparationGate460()
        defer { gate.release() }
        chat.providerConstructionPauseForTests = { await gate.wait() }
        #expect(chat.retryFailedSession(failed))
        let admitted = try #require(chat.activeExecutionIdentity(for: id))
        let runID = try AgentLoopChatEngine.generatedContextManifestRunID(for: admitted)
        try await waitForPause(gate)
        #expect(chat.executionSnapshot(forSessionID: id)?.state == .running)
        #expect(manifests.manifest(runID: runID) == nil)
        let enabledNextSoul = try souls.setActive(nextSoul.id)
        #expect(SoulStore(directory: souls.directory).activeSoul() == enabledNextSoul)
        let frozenRuntime = ChatSessionRuntime(sessionStore: sessions, memoryStore: memory,
            skillStore: skills, soulStore: souls, soulTurnSelection: .frozen(firstSoul),
            provider: provider, toolExecutor: executor)
        let frozenContext = try await frozenRuntime.makeContext(sessionID: id.uuidString)
        #expect(frozenContext.personaID == firstSoul.id)
        let dryRun = try await frozenRuntime.send(ChatTurnRequest(
            text: "Synthetic existing turn", context: frozenContext, operationMode: .plan))
        #expect(dryRun.isDryRun)
        #expect(dryRun.context.personaID == firstSoul.id)
        let liveRuntime = ChatSessionRuntime(sessionStore: sessions, memoryStore: memory,
            skillStore: skills, soulStore: souls, provider: provider, toolExecutor: executor)
        #expect(try await liveRuntime.makeContext(sessionID: id.uuidString).personaID == nextSoul.id)
        gate.release()
        let deadline = ContinuousClock.now + .seconds(8)
        while manifests.manifest(runID: runID) == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let admittedManifest = try #require(manifests.manifest(runID: runID))
        let admittedPrompt = try #require(admittedManifest.entries.first {
            $0.identifier == "system-prompt"
        })
        #expect(admittedManifest.snapshot.providerID == record.name)
        #expect(admittedManifest.snapshot.modelID == "retry-model")
        // The admitted hash covers the full system prompt. The reference was
        // captured at the provider, before changing the selected model for retry.
        let environmentStart = try #require(referencePrompt.range(of: "\n\n当前日期：", options: .backwards))
        let referenceBase = referencePrompt[..<environmentStart.lowerBound]
        // Soul 由运行时拼在环境尾之后，所以在完整提示里核对，不在环境尾之前的部分里找。
        _ = referenceBase
        #expect(referencePrompt.contains(firstSoul.systemPrompt))
        #expect(!referencePrompt.contains(nextSoul.systemPrompt))
        var environmentLines = referencePrompt[environmentStart.lowerBound...]
            .split(separator: "\n", omittingEmptySubsequences: false)
        let modelLines = environmentLines.indices.filter { environmentLines[$0].hasPrefix("当前模型：") }
        let modelLine = try #require(modelLines.first)
        try #require(modelLines.count == 1)
        try #require(environmentLines[modelLine] == "当前模型：" + provider.model.id)
        environmentLines[modelLine] = Substring("当前模型：" + admittedManifest.snapshot.modelID)
        let expectedRetryPrompt = String(referenceBase) + environmentLines.joined(separator: "\n")
        #expect(admittedPrompt.contentHash == ContextItem.hash(
            content: expectedRetryPrompt, identifier: admittedPrompt.identifier))
        #expect(provider.requests.count == 1)
        #expect(executor.count == 0)
        #expect(ledger.facts.isEmpty)

        while chat.isStreaming && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!chat.isStreaming)
        chat.providerConstructionPauseForTests = nil
        chat.streamingProviderOverride = provider
        chat.draftText = "Next request with Soul B"
        chat.sendDraft()
        try await waitForReply(chat, provider: provider, count: 2)
        let nextPrompt = try #require(provider.requests.last?.systemPrompt)
        #expect(nextPrompt.contains(nextSoul.systemPrompt))
        #expect(!nextPrompt.contains(firstSoul.systemPrompt))
        #expect(nextPrompt != referencePrompt)
        #expect(executor.count == 0)
        #expect(ledger.facts.isEmpty)
    }

    @Test("ordinary send freezes A while preserving B draft, callbacks and durable ownership")
    func ordinarySendKeepsSnapshotDraftAndDurableAttachmentOwnership517() async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("composer517-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: "composer517-" + root.lastPathComponent))
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let a = UUID(), b = UUID()
        for id in [a, b] {
            _ = try sessions.createSession(id: id.uuidString, title: "Owned composer517",
                projectID: "project517", projectName: "Synthetic 517", workingDirectory: root.path)
        }
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        let drafts = DraftStore(directory: root.appendingPathComponent("drafts"))
        let log = LogManager(directory: root.appendingPathComponent("logs"))
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let souls = SoulStore(directory: root.appendingPathComponent("souls"))
        try souls.upsert(Soul(id: "owned517", name: "Owned 517", systemPrompt: "Synthetic expression", isActive: true))
        let settings = center(root: root, defaults: defaults, sessions: sessions,
            memory: memory, skills: skills, log: log, readiness: readiness)
        let chat = ChatStore(providerReadinessStore: readiness, preferencesDefaults: defaults, logManager: log)
        defer { chat.stopAllStreamingForSafety() }
        #expect(chat.attachPersistence(sessions, badgeStore: badges))
        chat.attachDraftStore(drafts)
        let manager = try #require(chat.sessionManager)
        #expect(manager.store === sessions && manager.badgeStore === badges)
        #expect(manager.store.directory.pathComponents == root.appendingPathComponent("sessions").pathComponents)
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "composer517-policy", grantEpoch: "composer517-epoch",
            leaseID: "composer517-lease", expiresAt: .distantFuture, autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = .init(mode: .plan, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        chat.configureBudget(from: settings.settingsStore.settings.agent)
        let executor = PersonaToolExecutor460()
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        let tasks = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: executor, taskStore: tasks,
            chatRuntimeDependencies: .init(sessionStore: sessions, memoryStore: memory,
                skillStore: skills, soulStore: souls),
            contextWritebackStorePersistenceURL: root.appendingPathComponent("context.json"),
            toolExecutionFactLedger: ledger, composerPolicyFacts: facts).withRequestBudget(chat.budgetTracker)
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        chat.effectiveSettingsSnapshotSource = { settings.bl6EffectiveSettingsSnapshot }
        let providerA = PersonaRequestProvider460(), providerB = PersonaRequestProvider460()
        providerA.model = LLMModel(id: "composer517-model-a", displayName: "Owned model A", provider: providerA.name)
        providerB.model = LLMModel(id: "composer517-model-b", displayName: "Owned model B", provider: providerB.name)
        let aBytes = Data("COMPOSER517_ATTACHMENT_A".utf8)
        let bBytes = Data("COMPOSER517_ATTACHMENT_B".utf8)
        let sourceA = root.appendingPathComponent("a.md"), sourceB = root.appendingPathComponent("b.md")
        try aBytes.write(to: sourceA)
        try bBytes.write(to: sourceB)
        let aAttachment = ChatAttachment(kind: .text, fileName: "a.md", fileType: .markdown,
            size: Int64(aBytes.count), data: aBytes, fileURL: sourceA.path)
        let bAttachment = ChatAttachment(kind: .text, fileName: "b.md", fileType: .markdown,
            size: Int64(bBytes.count), data: bBytes, fileURL: sourceB.path)
        let aText = "COMPOSER517_BODY_A", bText = "COMPOSER517_UNSENT_BODY_B"
        #expect(chat.applySwitchSession(id: b))
        chat.draftText = bText
        chat.addComposerDraftAttachment(bAttachment)
        #expect(drafts.latestPayload(for: DraftStore.chatDraftKey(sessionID: b)) == Data(bText.utf8))
        // Match the existing lifecycle persistence boundary: the ChatStore
        // seam encodes long drafts; DraftStore flushes pending short drafts.
        #expect(chat.flushPendingDraftForTermination())
        #expect(drafts.flushAll())
        let bKey = DraftStore.chatDraftKey(sessionID: b)
        let bDraftBytes = try #require(drafts.load(key: bKey))
        #expect(bDraftBytes == Data(bText.utf8))
        #expect(chat.applySwitchSession(id: a))
        chat.streamingProviderOverride = providerA
        chat.draftText = aText
        chat.addComposerDraftAttachment(aAttachment)
        #expect(chat.flushPendingDraftForTermination())
        #expect(drafts.flushAll())
        let aKey = DraftStore.chatDraftKey(sessionID: a)
        #expect(drafts.load(key: aKey) == Data(aText.utf8))
        // Take the full B record only after both explicit baseline flushes;
        // ordinary flushes may legitimately refresh the envelope's savedAt.
        let bRecordURL = drafts.draftsDirectory.appendingPathComponent(bKey + ".json")
        let bRecordBeforeA = try Data(contentsOf: bRecordURL)
        let gate = PersonaPreparationGate460()
        defer { gate.release() }
        chat.turnPromptPreprocessPauseForTests = { await gate.wait() }
        chat.submitComposer()
        let snapshot = try #require(chat.lastComposerSubmissionSnapshot)
        let sentA = try #require(chat.messages(forSession: a)?.last(where: { $0.role == .user }))
        #expect(snapshot.sessionID == a.uuidString && snapshot.messageID == sentA.id.uuidString)
        #expect(chat.draftText.isEmpty && chat.pendingAttachments.isEmpty)
        #expect(drafts.load(key: aKey) == nil && drafts.latestPayload(for: aKey) == nil)
        try await waitForPause(gate)
        #expect(providerA.requests.isEmpty && providerB.requests.isEmpty)
        // Typing while A is paused belongs to its next draft, never its sent
        // content. The immediate clear above has already proved no old revival.
        let inFlightNextA = "COMPOSER517_TYPED_DURING_A"
        chat.draftText = inFlightNextA

        // Switch and change B's model only after A's request entry has frozen.
        #expect(chat.applySwitchSession(id: b))
        chat.streamingProviderOverride = providerB
        #expect(chat.draftText == bText && chat.pendingAttachments == [bAttachment])
        #expect(drafts.load(key: bKey) == bDraftBytes)
        #expect(try Data(contentsOf: bRecordURL) == bRecordBeforeA)
        let bSessionBefore = try #require(sessions.loadSession(id: b.uuidString))
        let bSessionURL = sessions.sessionsDirectory.appendingPathComponent(b.uuidString + ".json")
        let bSessionBytesBefore = try Data(contentsOf: bSessionURL)
        // TASK685: exercise the original resolver commit while A is still
        // in flight, with B active. The held production preprocessing task
        // cannot reach either Provider until these assertions have run.
        let pausedAURL = sessions.sessionsDirectory.appendingPathComponent(a.uuidString + ".json")
        let pausedABytes = try Data(contentsOf: pausedAURL)
        let pausedSidecarURL = ChatAttachmentPersistence.sessionSidecarURL(for: a, in: sessions.directory)
        let pausedSidecarBytes = try Data(contentsOf: pausedSidecarURL)
        let inFlightLate = ChatAttachment(id: aAttachment.id, kind: .text,
            fileName: aAttachment.fileName, fileType: .markdown,
            data: Data("COMPOSER685_INFLIGHT_LATE_POISON".utf8), fileURL: sourceA.path)
        #expect(chat.messages(forSession: a)?.last(where: { $0.role == .assistant })?.isStreaming == true)
        #expect(providerA.requests.isEmpty && providerB.requests.isEmpty)
        chat.applyComposerAttachmentResolution(inFlightLate, sessionID: a)
        chat.applyComposerAttachmentResolution(inFlightLate, sessionID: b)
        #expect(chat.messages(forSession: a)?.first(where: { $0.id == sentA.id }) == sentA)
        #expect(chat.lastComposerSubmissionSnapshot == snapshot)
        #expect(chat.draftText == bText && chat.pendingAttachments == [bAttachment])
        #expect(try Data(contentsOf: pausedAURL) == pausedABytes)
        #expect(try Data(contentsOf: pausedSidecarURL) == pausedSidecarBytes)
        #expect(try Data(contentsOf: bSessionURL) == bSessionBytesBefore)
        print("COMPOSER685_INFLIGHT a=\(a) b=\(b) message=\(sentA.id) attachment=\(aAttachment.id) phase=preprocessor-paused sent-and-sidecar-unchanged=true provider-calls=0")
        chat.turnPromptPreprocessPauseForTests = nil
        gate.release()
        try await waitForReply(chat, provider: providerA, count: 1)
        // The active B streaming flag cannot prove background A is terminal.
        for _ in 0..<300 {
            if chat.messages(forSession: a)?.last(where: { $0.role == .assistant })?.turnTiming?.finishedAt != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(chat.messages(forSession: a)?.last(where: { $0.role == .assistant })?.turnTiming?.finishedAt != nil)
        #expect(providerB.requests.isEmpty)
        let actualA = try #require(providerA.requests.first?.messages.last(where: { $0.role == .user }))
        #expect(actualA == sentA.asLLMMessage())
        #expect(actualA.content.contains(aText) && actualA.content.contains("COMPOSER517_ATTACHMENT_A"))
        #expect(!actualA.content.contains(bText) && !actualA.content.contains("COMPOSER517_ATTACHMENT_B"))
        #expect(chat.draftText == bText && chat.pendingAttachments == [bAttachment])
        #expect(drafts.load(key: bKey) == bDraftBytes)
        #expect(try Data(contentsOf: bRecordURL) == bRecordBeforeA)
        #expect(drafts.load(key: aKey) == Data(inFlightNextA.utf8))
        #expect(!actualA.content.contains(inFlightNextA))
        #expect(try Data(contentsOf: bSessionURL) == bSessionBytesBefore)
        #expect(sessions.loadSession(id: b.uuidString)?.messages == bSessionBefore.messages)
        let completeA = try #require(chat.messages(forSession: a))
        #expect(completeA.first(where: { $0.id == sentA.id }) == sentA)
        #expect(completeA.last(where: { $0.role == .assistant })?.turnModelID == providerA.model.id)
        let aSessionURL = sessions.sessionsDirectory.appendingPathComponent(a.uuidString + ".json")
        let persistedA = try #require(sessions.loadSession(id: a.uuidString))
        #expect(persistedA.messages.last(where: { $0.role == .user }) == sentA.asLLMMessage())
        let sidecarURL = ChatAttachmentPersistence.sessionSidecarURL(for: a, in: sessions.directory)
        let sidecarBytes = try Data(contentsOf: sidecarURL)

        // These are real stale resolver commits; they cannot search sent rows.
        let late = ChatAttachment(id: aAttachment.id, kind: .text, fileName: aAttachment.fileName,
            fileType: .markdown, data: Data("COMPOSER517_LATE_POISON".utf8), fileURL: sourceA.path)
        chat.applyComposerAttachmentResolution(late, sessionID: a)
        #expect(chat.draftText == bText && chat.pendingAttachments == [bAttachment])
        #expect(chat.applySwitchSession(id: a))
        #expect(chat.draftText == inFlightNextA && chat.draftText != aText && chat.pendingAttachments.isEmpty)
        // Opening A marks it read by existing product semantics. Freeze disk
        // bytes after that intentional metadata action, before stale commits.
        let aSessionBytes = try Data(contentsOf: aSessionURL)
        chat.beginEdit(messageID: sentA.id)
        chat.draftText = "COMPOSER517_NEXT_EDIT_A"
        chat.applyComposerAttachmentResolution(late, sessionID: a)
        #expect(chat.messages(forSession: a) == completeA)
        #expect(chat.lastComposerSubmissionSnapshot == snapshot)
        #expect(try Data(contentsOf: aSessionURL) == aSessionBytes)
        #expect(try Data(contentsOf: sidecarURL) == sidecarBytes)
        let reopened = ChatStore(providerReadinessStore: readiness, preferencesDefaults: defaults, logManager: log)
        defer { reopened.stopAllStreamingForSafety() }
        #expect(reopened.attachPersistence(SessionStore(directory: sessions.directory), badgeStore: badges))
        #expect(reopened.applySwitchSession(id: a))
        // UI message IDs/timestamps are newly constructed on reopen. Durable
        // ownership binds the canonical index+content digest and attachment ID.
        let restoredA = try #require(reopened.messages.first(where: {
            $0.role == .user && $0.content == sentA.content
        }))
        #expect(restoredA.asLLMMessage() == sentA.asLLMMessage())
        #expect(restoredA.attachments == [aAttachment])
        let recordsA = try #require(try ChatAttachmentPersistence.load(forSessionID: a.uuidString, from: sessions.directory))
        let ownedA = try #require(recordsA.first(where: { $0.attachments.contains(where: { $0.id == aAttachment.id }) }))
        let canonicalA = try #require(sessions.loadSession(id: a.uuidString))
        try #require(canonicalA.messages.indices.contains(ownedA.messageIndex))
        #expect(canonicalA.messages[ownedA.messageIndex] == sentA.asLLMMessage())
        let expectedDigest = SHA256.hash(data: Data(sentA.content.utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(ownedA.contentDigest == expectedDigest)
        #expect(ownedA.attachments == [aAttachment])
        #expect(reopened.applySwitchSession(id: b))
        #expect(reopened.messages.allSatisfy { $0.attachments.isEmpty && !$0.content.contains(aText) })

        #expect(chat.applySwitchSession(id: b))
        #expect(chat.draftText == bText && chat.pendingAttachments == [bAttachment])
        chat.streamingProviderOverride = providerB
        chat.submitComposer()
        try await waitForReply(chat, provider: providerB, count: 1)
        let sentB = try #require(chat.messages(forSession: b)?.last(where: { $0.role == .user }))
        #expect(providerB.requests.last?.messages.last(where: { $0.role == .user }) == sentB.asLLMMessage())
        #expect(sentB.content.contains(bText) && sentB.attachments == [bAttachment])
        #expect(!sentB.content.contains(aText) && !sentB.content.contains("COMPOSER517_LATE_POISON"))
        #expect(chat.messages(forSession: b)?.last(where: { $0.role == .assistant })?.turnModelID == providerB.model.id)
        #expect(chat.messages(forSession: a) == completeA)
        #expect(try Data(contentsOf: aSessionURL) == aSessionBytes)
        #expect(providerA.requests.count == 1 && providerB.requests.count == 1)
        #expect(drafts.load(key: bKey) == nil)
        #expect(chat.applySwitchSession(id: a))
        #expect(chat.draftText == "COMPOSER517_NEXT_EDIT_A")
        #expect(chat.composerPolicyFacts == facts && ledger.facts.isEmpty && executor.count == 0)
        #expect(providerA.streamCallCount == 0 && providerB.streamCallCount == 0)
        // Keep the wholly synthetic fixture. Existing SettingsCenter default
        // dependencies retain the documented V7/UNKNOWN boundary.
    }
}


// D-RECOVERY-04: persist the existing settings and skill lifecycle toggles,
// then rebuild their stores before the actual ordinary request consumer.
// External model responses reuse the existing local Provider boundary.
extension PersonaSoulNextRequest460Tests {
    @Test(arguments: [false, true])
    func reopenedMemoryAndSkillTogglesReachActualNextRequest824(memoryEnabled: Bool) async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "recovery824", processEnvironment: [:],
            processArguments: ["Recovery824Tests.xctest"], canvasRuntimeState: .disabled)
        let root = profile.rootDirectory
        let defaults = profile.makeUserDefaults()
        defer {
            if let suite = profile.userDefaultsSuiteName { defaults.removePersistentDomain(forName: suite) }
            try? profile.cleanupDisposableRoots()
        }
        let id = UUID()
        let globalID = UUID()
        let sessionRoot = root.appendingPathComponent("sessions824")
        let memoryRoot = root.appendingPathComponent("memory824")
        let skillRoot = root.appendingPathComponent("skills824")
        let stateURL = root.appendingPathComponent("skill-state824.json")
        let sessions = SessionStore(directory: sessionRoot)
        _ = try sessions.createSession(id: id.uuidString, title: "owned recovered feature state",
            projectID: "project824", projectName: "Owned 824", workingDirectory: root.path)
        _ = try sessions.createSession(id: globalID.uuidString, title: "owned global skill recovery",
            workingDirectory: root.path)
        let scope = MemoryScope(sessionID: id.uuidString, projectID: "project824")
        let memory = MemoryStore(directory: memoryRoot)
        let memoryMarker = "MEMORY824_SYNTHETIC_FACT"
        _ = try memory.addFact("orbit824 preference " + memoryMarker,
            sourceSessionID: id.uuidString, memoryScope: scope)
        let skills = SkillStore(skillsRoot: skillRoot)
        let skillMarker = "SKILL824_SYNTHETIC_BODY"
        let imported = try skills.importSkillThroughLifecycle(content: """
            ---
            name: recovery824-skill
            description: recovery824 orbit824 owned synthetic skill
            version: 1
            ---
            \(skillMarker)
            """, source: .file, reason: "owned recovery824 fixture",
            approval: SkillApproval(approverID: "recovery824-owned"))
        let facade = SkillsStore(
            appStore: skills, stateFileURL: stateURL)
        let souls = SoulStore(directory: root.appendingPathComponent("souls824"))
        try souls.upsert(Soul(id: "owned824", name: "Owned recovery dependency",
            systemPrompt: "Synthetic expression only.", isActive: true))
        let log = LogManager(directory: root.appendingPathComponent("logs824"))
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness824"))
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges824"))
        // Reuse SettingsCenter's existing explicit dependencies, including
        // the current badge seam; no default user BadgeStore is constructed.
        func reopenedCenter(sessions: SessionStore, memory: MemoryStore, skills: SkillStore) -> SettingsCenter {
            let keychain = KeychainStore(backing: InMemoryKeychainBacking())
            return SettingsCenter(
                settingsStore: SettingsStore(directory: root.appendingPathComponent("settings824")),
                envStore: EnvVarStore(directory: root.appendingPathComponent("env824"), keychain: keychain,
                    privacyStore: EnvVarPrivacyStore(defaults: defaults)),
                memoryStore: memory,
                memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files824")),
                sessionStore: sessions, sessionBadgeStore: badges, logManager: log,
                mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp824.json"), keychain: keychain),
                skillStore: skills, usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain),
                providerReadinessTransport: FailClosedProviderReadinessTransport(),
                providerReadinessDeployment: .mock, providerReadinessStore: readiness)
        }
        let writer = reopenedCenter(sessions: sessions, memory: memory, skills: skills)
        writer.memoryEnabled = memoryEnabled
        let expectedMemory = try memory.facts()
        let expectedMemoryBytes = try Data(contentsOf: memory.fileURL)

        // Independent combinations distinguish each toggle from a single
        // shared switch, and include a genuine restored enabled request.
        for (phase, skillEnabled) in [false, true].enumerated() {
            guard case .success = facade.setEnabled("app:" + imported.skill.id, enabled: skillEnabled) else {
                Issue.record("Owned skill enablement producer failed")
                return
            }
            let expectedStateBytes = try Data(contentsOf: stateURL)
            let expectedSettingsBytes = try Data(contentsOf: writer.settingsStore.fileURL)
            let activeSessions = SessionStore(directory: sessionRoot)
            let activeMemory = MemoryStore(directory: memoryRoot)
            let activeSkills = SkillStore(skillsRoot: skillRoot)
            let reopenedFacade = SkillsStore(
                appStore: activeSkills, stateFileURL: stateURL)
            let owner = reopenedCenter(sessions: activeSessions, memory: activeMemory, skills: activeSkills)
            #expect(owner.settingsStore !== writer.settingsStore)
            #expect(activeSessions !== sessions && activeMemory !== memory && activeSkills !== skills)
            #expect(owner.memoryEnabled == memoryEnabled)
            #expect(reopenedFacade.isEnabled("app:" + imported.skill.id) == skillEnabled)
            let lifecycle = try #require(activeSkills.lifecycleReceipt(for: imported.skill.id))
            #expect(lifecycle.contentHash == imported.receipt.contentHash)
            #expect(lifecycle.scope == nil && lifecycle.state == .active)
            #expect(try activeMemory.facts() == expectedMemory)
            let chat = ChatStore(providerReadinessStore: readiness, preferencesDefaults: defaults, logManager: log)
            defer { chat.stopAllStreamingForSafety() }
            #expect(chat.attachPersistence(activeSessions, badgeStore: badges))
            let manager = try #require(chat.sessionManager)
            #expect(manager.store === activeSessions && manager.badgeStore === badges)
            #expect(manager.store.directory.isFileURL)
            #expect(manager.store.directory.pathComponents == sessionRoot.pathComponents)
            #expect(chat.applySwitchSession(id: id))
            #expect(chat.activeMemoryScope == scope)
            let policy = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
                workspaceID: chat.composerWorkspaceID, revision: "recovery824-policy", grantEpoch: "recovery824-epoch",
                leaseID: "recovery824-lease", expiresAt: .distantFuture, autonomyCeiling: .l3)
            chat.configureComposerPolicy(policy)
            chat.composerPolicySelection = .init(mode: .plan, approvalScope: .request,
                effort: .standard, bypassModeConfirmed: false)
            chat.configureBudget(from: owner.settingsStore.settings.agent)
            chat.memoryInjector = MemoryInjector(store: activeMemory)
            chat.memoryEnabledProvider = { owner.memoryEnabled }
            chat.effectiveSettingsSnapshotSource = { owner.bl6EffectiveSettingsSnapshot }
            let executor = PersonaToolExecutor460()
            let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts824-\(phase).json"))
            let tasks = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks824-\(phase).json"))
            let engine = AgentLoopChatEngine(toolExecutor: executor, taskStore: tasks,
                chatRuntimeDependencies: .init(sessionStore: activeSessions, memoryStore: activeMemory,
                    skillStore: activeSkills, soulStore: souls),
                contextWritebackStorePersistenceURL: root.appendingPathComponent("context824-\(phase).json"),
                toolExecutionFactLedger: ledger, composerPolicyFacts: policy)
            chat.agentEngine = engine.withRequestBudget(chat.budgetTracker)
            chat.turnRuntimeSnapshotFactory = { turn, _ in
                .init(turn: turn, skillInjector: SkillInjector(store: activeSkills).snapshotForTurn(), mcpBridge: nil)
            }
            let provider = PersonaRequestProvider460()
            chat.streamingProviderOverride = provider
            let prior = try #require(activeSessions.loadSession(id: id.uuidString))
            let text = "orbit824 recovery824-skill ordinary conversation after persisted restart"
            chat.draftText = text
            chat.sendDraft()
            try await waitForReply(chat, provider: provider, count: 1)
            let request = try #require(provider.requests.first)
            let prompt = try #require(request.systemPrompt)
            #expect(prompt.contains(memoryMarker) == memoryEnabled)
            // A global approval is not a project-scoped approval. The real
            // project request must continue to reject this nil-scope skill.
            #expect(!prompt.contains(skillMarker))
            #expect(request.messages == prior.messages + [LLMMessage(role: .user, content: text)])
            #expect(provider.streamCallCount == 0 && executor.count == 0 && ledger.facts.isEmpty)
            let projectReceipts = chat.lastSkillInjectionReceipts.filter { $0.skillID == imported.skill.id }
            #expect(!projectReceipts.contains(where: { $0.injected }))
            let completed = try #require(activeSessions.loadSession(id: id.uuidString))
            #expect(Array(completed.messages.prefix(prior.messages.count)) == prior.messages)
            #expect(completed.messages.last?.content == "460 synthetic completion")
            let projectSessionBytes = try Data(contentsOf: activeSessions.sessionsDirectory.appendingPathComponent(id.uuidString + ".json"))

            // Existing global-only enablement is consumed in a real persisted
            // nonproject session. Its scope is derived by ChatStore, never set
            // by this fixture or supplied as an alternate grant.
            #expect(chat.applySwitchSession(id: globalID))
            #expect(chat.activeMemoryScope == nil)
            let globalPrior = try #require(activeSessions.loadSession(id: globalID.uuidString))
            #expect(globalPrior.projectID == nil)
            chat.draftText = text
            chat.sendDraft()
            try await waitForReply(chat, provider: provider, count: 2)
            let globalRequest = try #require(provider.requests.last)
            let globalPrompt = try #require(globalRequest.systemPrompt)
            #expect(globalPrompt.contains(skillMarker) == skillEnabled)
            #expect(!globalPrompt.contains(memoryMarker))
            #expect(globalRequest.messages == globalPrior.messages + [LLMMessage(role: .user, content: text)])
            #expect(provider.requests.count == 2)
            #expect(provider.streamCallCount == 0 && executor.count == 0 && ledger.facts.isEmpty)
            let receipts = chat.lastSkillInjectionReceipts.filter { $0.skillID == imported.skill.id }
            #expect(receipts.contains(where: { $0.injected }) == skillEnabled)
            if skillEnabled {
                let injected = try #require(receipts.first { $0.injected })
                #expect(injected.contentHash == imported.receipt.contentHash)
                #expect(injected.version == imported.skill.version && injected.state == .active)
            }
            #expect(try activeMemory.facts() == expectedMemory)
            #expect(try Data(contentsOf: activeMemory.fileURL) == expectedMemoryBytes)
            #expect(try Data(contentsOf: stateURL) == expectedStateBytes)
            #expect(try Data(contentsOf: owner.settingsStore.fileURL) == expectedSettingsBytes)
            #expect(activeSkills.lifecycleReceipt(for: imported.skill.id) == lifecycle)
            #expect(activeSessions.loadSession(id: id.uuidString) == completed)
            #expect(try Data(contentsOf: activeSessions.sessionsDirectory.appendingPathComponent(id.uuidString + ".json")) == projectSessionBytes)
            let globalCompleted = try #require(activeSessions.loadSession(id: globalID.uuidString))
            #expect(Array(globalCompleted.messages.prefix(globalPrior.messages.count)) == globalPrior.messages)
            #expect(globalCompleted.messages.last?.content == "460 synthetic completion")
        }
    }
}
