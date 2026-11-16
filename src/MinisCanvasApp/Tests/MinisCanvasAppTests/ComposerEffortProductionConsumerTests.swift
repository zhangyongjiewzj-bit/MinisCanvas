import Foundation
import Testing
@testable import MinisCanvasApp
@testable import MinisCore

private final class ComposerContextBudgetProvider: LLMProvider, @unchecked Sendable {
    var model = LLMModel(
        id: "synthetic-context-model",
        displayName: "Synthetic Context Model",
        provider: "synthetic-context-provider",
        contextWindow: 8192,
        maxOutputTokens: 8192
    )
    var name: String { model.provider }
    var capabilities: Set<ProviderCapability> { [] }
    private(set) var receivedMaxTokens: [Int] = []
    private(set) var receivedHistory: [[LLMMessage]] = []
    var scriptedResponses: [LLMResponse] = []

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        receivedHistory.append(messages)
        receivedMaxTokens.append(maxTokens)
        if !scriptedResponses.isEmpty {
            return scriptedResponses.removeFirst()
        }
        return LLMResponse(text: "done", stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?,
        tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages, systemPrompt: systemPrompt,
            maxTokens: maxTokens, temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class ContextManifestBuildCounter696: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

// These consumers install different SettingsCenter.active owners. Keep each
// owner's SessionStore scope bound for the whole turn before the next starts.
@Suite("Composer effort production consumer", .serialized)
@MainActor
struct ComposerEffortProductionConsumerTests {
    @Test("AgentLoop production call receives the immutable Composer snapshot")
    func productionCallPassesSnapshotToAgentLoop() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: sourceRoot.appendingPathComponent(
                "Sources/MinisCanvasApp/ChatAgentEngine.swift"
            ),
            encoding: .utf8
        )
        let runBody = try #require(
            Self.balancedCallBody(
                in: source,
                marker: "productionLoop.run("
            ),
            "The App production consumer must invoke the production AgentLoop."
        )

        #expect(
            runBody.contains("composerSnapshot: composerSnapshot"),
            "The production AgentLoop call must consume the frozen Composer snapshot."
        )
        #expect(runBody.contains("maxTokens: loopOutputTokenBudget.baseMaxTokens"))
        #expect(runBody.contains("maxOutputTokensCeiling: loopOutputTokenBudget.hardCeiling"))
        let budgetCall = try #require(Self.balancedCallBody(
            in: source, marker: "let loopOutputTokenBudget = Self.agentLoopOutputTokenBudget("
        ))
        #expect(budgetCall.contains("baseMaxTokens: turnMaxTokens"))
        #expect(budgetCall.contains("hardCeiling: outputTokenBudget.hardCeiling"))
        #expect(budgetCall.contains("isMM01Scenario: mm01AgentScenario != nil"))
        // Execute the same final production budget boundary. These values must
        // remain independent; effort belongs to Core and is not applied here.
        for ceiling: Int? in [nil, 730] {
            let ordinary = AgentLoopChatEngine.agentLoopOutputTokenBudget(
                baseMaxTokens: 421, hardCeiling: ceiling, isMM01Scenario: false)
            #expect(ordinary.baseMaxTokens == 421)
            #expect(ordinary.hardCeiling == ceiling)
            let synthetic = AgentLoopChatEngine.agentLoopOutputTokenBudget(
                baseMaxTokens: 421, hardCeiling: ceiling, isMM01Scenario: true)
            #expect(synthetic.baseMaxTokens == 256)
            #expect(synthetic.hardCeiling == 256)
        }
        #expect(runBody.contains("contextSettings: contextSettings"))
        // Match the actual async invocation, independent of assignment or return.
        let manifestBody = try #require(Self.balancedCallBody(
            in: source,
            marker: "try await prepareContextManifest("
        ))
        #expect(manifestBody.contains("maxTokens: providerMaxTokens"))
        #expect(manifestBody.contains("requestedMaxTokens: turnMaxTokens"))
        #expect(
            !source.contains("let effortProfile = composerSnapshot.map"),
            "The App production consumer must not derive effort a second time."
        )
        #expect(
            !source.contains("productionLoop.maxIterations = effortProfile.maxIterations"),
            "The App production consumer must not override AgentLoop iterations."
        )
        #expect(
            !runBody.contains("maxTokens: effortProfile?.maxTokens ?? maxTokens"),
            "The App production consumer must not override AgentLoop tokens."
        )
    }

    @Test("Selected context retains an independent output ceiling")
    func selectedContextBudgetKeepsBaseAndHardCeilingSeparate() throws {
        let messages = [LLMMessage(role: .user, content: "abcdefgh")]
        let settings = try #require(ContextTurnSettingsSnapshot(
            sessionID: "synthetic-session",
            modelID: "synthetic-model",
            modelContextWindowTokens: 8192,
            requestedContextLengthTokens: 13,
            historyTurnLimit: nil
        ))
        let clipped = try AgentLoopChatEngine.outputTokenBudgetForContextTurn(
            messages,
            systemPrompt: "abcd",
            requestedMaxTokens: 1000,
            settings: settings
        )
        #expect(clipped.baseMaxTokens == 10)
        #expect(clipped.hardCeiling == 10)

        let roomy = try #require(ContextTurnSettingsSnapshot(
            sessionID: "synthetic-session",
            modelID: "synthetic-model",
            modelContextWindowTokens: 8192,
            requestedContextLengthTokens: 8003,
            historyTurnLimit: nil
        ))
        let budget = try AgentLoopChatEngine.outputTokenBudgetForContextTurn(
            messages,
            systemPrompt: "abcd",
            requestedMaxTokens: 1000,
            settings: roomy
        )
        #expect(budget.baseMaxTokens == 1000)
        #expect(budget.hardCeiling == 8000)
        let modelCapped = try AgentLoopChatEngine.outputTokenBudgetForContextTurn(
            messages,
            systemPrompt: "abcd",
            requestedMaxTokens: 1000,
            settings: roomy,
            modelMaxOutputTokens: 1200
        )
        #expect(modelCapped.baseMaxTokens == 1000)
        #expect(modelCapped.hardCeiling == 1200)

        let automatic = try #require(ContextTurnSettingsSnapshot(
            sessionID: "synthetic-session",
            modelID: "synthetic-model",
            modelContextWindowTokens: 8192,
            requestedContextLengthTokens: nil,
            historyTurnLimit: nil
        ))
        let unbounded = try AgentLoopChatEngine.outputTokenBudgetForContextTurn(
            messages,
            systemPrompt: "abcd",
            requestedMaxTokens: 1000,
            settings: automatic
        )
        #expect(unbounded.baseMaxTokens == 1000)
        #expect(unbounded.hardCeiling == nil)
        #expect(ContextTurnSettingsSnapshot(
            sessionID: "synthetic-session",
            modelID: "synthetic-model",
            modelContextWindowTokens: 8192,
            requestedContextLengthTokens: 8193,
            historyTurnLimit: nil
        ) == nil)

        let exhausted = try #require(ContextTurnSettingsSnapshot(
            sessionID: "synthetic-session",
            modelID: "synthetic-model",
            modelContextWindowTokens: 8192,
            requestedContextLengthTokens: 3,
            historyTurnLimit: nil
        ))
        #expect(throws: AgentLoopChatEngine.ContextManifestConsumptionError.contextLengthExceeded) {
            _ = try AgentLoopChatEngine.outputTokenBudgetForContextTurn(
                messages,
                systemPrompt: "abcd",
                requestedMaxTokens: 1000,
                settings: exhausted
            )
        }
    }

    @Test("Production manifest tracks effective provider budgets with and without selected context")
    func selectedContextManifestMatchesActualProviderBudget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-context-budget-\(UUID().uuidString)")
        let sessionID = "synthetic-context-session"
        let sessionStore = SessionStore(directory: root.appendingPathComponent("sessions"))
        _ = try sessionStore.createSession(id: sessionID)
        try sessionStore.saveMessage(
            LLMMessage(role: .user, content: "abcdefgh"),
            sessionID: sessionID
        )
        let memoryStore = MemoryStore(directory: root.appendingPathComponent("memory"))
        let skillStore = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain),
            memoryStore: memoryStore,
            sessionStore: sessionStore,
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: skillStore,
            usageStore: UsageStore(domain: .suite("composer-context-budget-\(UUID().uuidString)")),
            providerReadinessTransport: FailClosedProviderReadinessTransport()
        )
        #expect(center.setContextLengthTokens(13))
        let provider = ComposerContextBudgetProvider()
        let manifestStore = ContextManifestStore()
        let turn = AgentTurnIdentity(
            sessionID: sessionID,
            turnID: 1,
            messageID: "synthetic-context-assistant"
        )
        let workspaceID = "synthetic-context-workspace"
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [],
            grantedCapabilities: [],
            allowedWriteRoots: [],
            workspaceID: workspaceID,
            revision: "synthetic-context-policy",
            grantEpoch: "synthetic-context-grant",
            leaseID: "synthetic-context-lease",
            expiresAt: .distantFuture,
            autonomyCeiling: .l1
        )
        let composerSnapshot = ComposerSubmissionSnapshot(
            mode: .manual,
            approvalScope: .request,
            effort: .high,
            sessionID: sessionID,
            turnID: turn.turnID,
            taskID: "synthetic-context-task",
            attemptID: "synthetic-context-attempt",
            messageID: turn.messageID,
            inputDigest: "synthetic-context-input",
            workspaceID: workspaceID,
            createdAt: Date(),
            policyRevision: facts.revision,
            grantEpoch: facts.grantEpoch,
            autonomyCeiling: .l1
        )
        let engine = AgentLoopChatEngine(
            toolExecutor: BuiltinToolExecutor(allowedRoot: root),
            contextManifestStore: manifestStore,
            chatRuntimeDependencies: .init(
                sessionStore: sessionStore,
                memoryStore: memoryStore,
                skillStore: skillStore,
                soulStore: SoulStore(directory: root.appendingPathComponent("soul"))
            ),
            composerPolicyFacts: facts
        )
        let executionIdentity = AgentExecutionIdentity(turn: turn)
        let stream = try await engine.streamReply(
            provider: provider,
            history: [ChatMessageUI(role: .user, content: "abcdefgh")],
            systemPrompt: "abcd",
            maxTokens: 1000,
            conversationID: sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: turn.turnID,
            composerSnapshot: composerSnapshot,
            executionIdentity: executionIdentity,
            turnRuntimeSnapshot: ChatTurnRuntimeSnapshot(
                turn: turn,
                skillInjector: SkillInjector(store: skillStore).snapshotForTurn(),
                mcpBridge: nil
            )
        )
        for try await _ in stream {}

        let recorded = try #require(provider.receivedMaxTokens.first)
        let manifest = try #require(manifestStore.manifest(runID: try AgentLoopChatEngine.generatedContextManifestRunID(for: executionIdentity)))
        let receipt = try #require(manifestStore.receipt(runID: try AgentLoopChatEngine.generatedContextManifestRunID(for: executionIdentity)))
        let selected = try #require({
            if case .accepted(let snapshot) = SettingsCenter.contextTurnSettingsSnapshot(
                for: sessionStore,
                sessionID: sessionID,
                model: provider.model
            ) { return snapshot }
            return nil
        }())
        #expect(provider.receivedMaxTokens == [10])
        #expect(recorded <= selected.contextLengthTokens - 3)
        #expect(manifest.snapshot.configurationFingerprint == "chat:v2:\(recorded):\(selected.revision)")
        #expect(receipt.requestedBudget == selected.contextLengthTokens)

        #expect(center.setContextLengthTokens(0))
        let nextTurn = AgentTurnIdentity(
            sessionID: sessionID,
            turnID: 2,
            messageID: "synthetic-context-assistant-next"
        )
        let nextSnapshot = ComposerSubmissionSnapshot(
            mode: .manual,
            approvalScope: .request,
            effort: .high,
            sessionID: sessionID,
            turnID: nextTurn.turnID,
            taskID: "synthetic-context-task-next",
            attemptID: "synthetic-context-attempt-next",
            messageID: nextTurn.messageID,
            inputDigest: "synthetic-context-input-next",
            workspaceID: workspaceID,
            createdAt: Date(),
            policyRevision: facts.revision,
            grantEpoch: facts.grantEpoch,
            autonomyCeiling: .l1
        )
        let nextIdentity = AgentExecutionIdentity(turn: nextTurn)
        let nextStream = try await engine.streamReply(
            provider: provider,
            history: [ChatMessageUI(role: .user, content: "abcdefgh")],
            systemPrompt: "abcd",
            maxTokens: 1000,
            conversationID: sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: nextTurn.turnID,
            composerSnapshot: nextSnapshot,
            executionIdentity: nextIdentity,
            turnRuntimeSnapshot: ChatTurnRuntimeSnapshot(
                turn: nextTurn,
                skillInjector: SkillInjector(store: skillStore).snapshotForTurn(),
                mcpBridge: nil
            )
        )
        for try await _ in nextStream {}
        let nextRunID = try AgentLoopChatEngine.generatedContextManifestRunID(for: nextIdentity)
        let nextManifest = try #require(manifestStore.manifest(runID: nextRunID))
        let nextReceipt = try #require(manifestStore.receipt(runID: nextRunID))
        #expect(provider.receivedMaxTokens == [10, 1500])
        #expect(nextManifest.snapshot.configurationFingerprint ==
            "chat:v1:\(provider.model.provider):\(provider.model.id):1500")
        #expect(nextReceipt.requestedBudget == 1000)
    }

    @Test("Production consumer shrinks the second Provider request after a tool result")
    func selectedContextRechecksActualProviderRequests() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-context-two-requests-\(UUID().uuidString)")
        let sessionID = "synthetic-context-two-requests"
        let sessionStore = SessionStore(directory: root.appendingPathComponent("sessions"))
        _ = try sessionStore.createSession(id: sessionID)
        try sessionStore.saveMessage(
            LLMMessage(role: .user, content: "read synthetic file"), sessionID: sessionID
        )
        let memoryStore = MemoryStore(directory: root.appendingPathComponent("memory"))
        let skillStore = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain),
            memoryStore: memoryStore,
            sessionStore: sessionStore,
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: skillStore,
            usageStore: UsageStore(domain: .suite("composer-context-two-requests-\(UUID().uuidString)")),
            providerReadinessTransport: FailClosedProviderReadinessTransport()
        )
        #expect(center.setContextLengthTokens(300))
        let path = root.appendingPathComponent("synthetic-tool-result.txt")
        try String(repeating: "x", count: 600).write(to: path, atomically: true, encoding: .utf8)
        let provider = ComposerContextBudgetProvider()
        provider.scriptedResponses = [
            LLMResponse(
                text: "reading", stopReason: "tool_calls", usage: nil,
                toolCalls: [LLMToolCall(
                    id: "synthetic-read", name: "file_read",
                    rawArguments: "{\"tool_title\":\"Read the synthetic tool result file\",\"path\":\"\(path.path)\"}",
                    arguments: [
                        "tool_title": "Read the synthetic tool result file",
                        "path": path.path
                    ]
                )]
            ),
            LLMResponse(text: "done", stopReason: "stop", usage: nil)
        ]
        let manifestStore = ContextManifestStore()
        let turn = AgentTurnIdentity(
            sessionID: sessionID, turnID: 1, messageID: "synthetic-context-two-requests-assistant"
        )
        let workspaceID = "synthetic-context-two-requests-workspace"
        let facts = ComposerPolicyFactSource(
            knownCapabilities: ["file_read"],
            grantedCapabilities: ["file_read"],
            allowedWriteRoots: [root.path],
            workspaceID: workspaceID,
            revision: "synthetic-context-two-requests-policy",
            grantEpoch: "synthetic-context-two-requests-grant",
            leaseID: "synthetic-context-two-requests-lease",
            expiresAt: .distantFuture,
            autonomyCeiling: .l1
        )
        let composerSnapshot = ComposerSubmissionSnapshot(
            mode: .manual,
            approvalScope: .request,
            effort: .standard,
            sessionID: sessionID,
            turnID: turn.turnID,
            taskID: "synthetic-context-two-requests-task",
            attemptID: "synthetic-context-two-requests-attempt",
            messageID: turn.messageID,
            inputDigest: "synthetic-context-two-requests-input",
            workspaceID: workspaceID,
            createdAt: Date(),
            policyRevision: facts.revision,
            grantEpoch: facts.grantEpoch,
            autonomyCeiling: .l1
        )
        let engine = AgentLoopChatEngine(
            toolExecutor: BuiltinToolExecutor(allowedRoot: root),
            contextManifestStore: manifestStore,
            chatRuntimeDependencies: .init(
                sessionStore: sessionStore,
                memoryStore: memoryStore,
                skillStore: skillStore,
                soulStore: SoulStore(directory: root.appendingPathComponent("soul"))
            ),
            toolExecutionFactLedger: try ToolExecutionFactLedger(
                persistenceURL: root.appendingPathComponent("tool-execution-facts-v4.json")
            ),
            composerPolicyFacts: facts
        )
        let selected = try #require({
            if case .accepted(let snapshot) = SettingsCenter.contextTurnSettingsSnapshot(
                for: sessionStore, sessionID: sessionID, model: provider.model
            ) { return snapshot }
            return nil
        }())
        let executionIdentity = AgentExecutionIdentity(
            turn: turn, operationID: "synthetic-context-two-requests-operation", attempt: 1)
        let stream = try await engine.streamReply(
            provider: provider,
            history: [ChatMessageUI(role: .user, content: "read synthetic file")],
            systemPrompt: "system",
            maxTokens: 1000,
            conversationID: sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: turn.turnID,
            composerSnapshot: composerSnapshot,
            executionIdentity: executionIdentity,
            turnRuntimeSnapshot: ChatTurnRuntimeSnapshot(
                turn: turn,
                skillInjector: SkillInjector(store: skillStore).snapshotForTurn(),
                mcpBridge: nil
            )
        )
        for try await _ in stream {}

        #expect(provider.receivedMaxTokens.count == 2)
        let first = try #require(provider.receivedHistory.first)
        let second = try #require(provider.receivedHistory.last)
        #expect(second.contains { $0.role == .tool && $0.content.contains(String(repeating: "x", count: 100)) })
        let firstCost = try #require(AgentContextTokenBudget.estimatedInputCost(
            first, systemPrompt: "system"
        ))
        let secondCost = try #require(AgentContextTokenBudget.estimatedInputCost(
            second, systemPrompt: "system"
        ))
        let firstMax = selected.contextLengthTokens - firstCost
        let secondMax = selected.contextLengthTokens - secondCost
        #expect(provider.receivedMaxTokens == [firstMax, secondMax])
        #expect(secondMax < firstMax)
        let manifest = try #require(manifestStore.manifest(runID: try AgentLoopChatEngine.generatedContextManifestRunID(for: executionIdentity)))
        #expect(manifest.snapshot.configurationFingerprint ==
            "chat:v2:\(firstMax):\(selected.revision)")
    }

    @Test("Actual context preparation builds once and retains explicit-input rejection",
          arguments: ["normal", "normal-first-turn-zero", "explicit-valid", "explicit-foreign", "normal-over-budget"])
    func actualContextBuildCountAndExplicitValidation696(route: String) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("context-single-build696-\(UUID().uuidString)")
        let sessionID = "context-single-build696-session"
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        _ = try sessions.createSession(id: sessionID)
        try sessions.saveMessage(LLMMessage(role: .user, content: "abcdefgh"), sessionID: sessionID)
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain),
            memoryStore: memory,
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: sessions,
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: skills,
            usageStore: UsageStore(domain: .suite("context-single-build696-\(UUID().uuidString)")),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        )
        #expect(center.setContextLengthTokens(13))
        let provider = ComposerContextBudgetProvider()
        let selected = try #require({
            if case .accepted(let value) = SettingsCenter.contextTurnSettingsSnapshot(
                for: sessions, sessionID: sessionID, model: provider.model
            ) { return value }
            return nil
        }())
        let turn = AgentTurnIdentity(sessionID: sessionID, turnID: route == "normal-first-turn-zero" ? 0 : 1,
                                     messageID: "context696-assistant")
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: "context696-workspace", revision: "context696-policy",
            grantEpoch: "context696-grant", leaseID: "context696-lease",
            expiresAt: .distantFuture, autonomyCeiling: .l1
        )
        let submission = ComposerSubmissionSnapshot(
            mode: .manual, approvalScope: .request, effort: .high,
            sessionID: sessionID, turnID: turn.turnID, taskID: "context696-task",
            attemptID: "context696-attempt", messageID: turn.messageID,
            inputDigest: "context696-input", workspaceID: facts.workspaceID,
            createdAt: Date(), policyRevision: facts.revision, grantEpoch: facts.grantEpoch,
            autonomyCeiling: .l1
        )
        let snapshot = ConversationContextSnapshotV1(
            sessionID: sessionID, providerID: provider.model.provider, modelID: provider.model.id,
            configurationFingerprint: "chat:v2:10:\(selected.revision)",
            skillIdentifiers: [], conversationID: sessionID
        )
        let item = ContextItem(identifier: "system-prompt", content: "abcd", tokenCost: 1,
                               level: .l0, scope: "conversation", provenance: "chat.system", required: true)
        let executionIdentity = AgentExecutionIdentity(turn: turn)
        let callerRunID = "chat:\(sessionID):\(turn.turnID)"
        let runID = route.hasPrefix("explicit-") ? callerRunID
            : try AgentLoopChatEngine.generatedContextManifestRunID(for: executionIdentity)
        let supplied: AgentLoopChatEngine.ContextManifestConsumerInput?
        if route.hasPrefix("explicit-") {
            let resultSnapshot = route == "explicit-foreign"
                ? ConversationContextSnapshotV1(
                    sessionID: "foreign-session", providerID: provider.model.provider,
                    modelID: provider.model.id, configurationFingerprint: "foreign-revision",
                    skillIdentifiers: [], conversationID: "foreign-session") : snapshot
            let result = ContextOrchestrator().makeManifest(
                .init(snapshot: resultSnapshot, contextItems: [item]), budget: 13
            )
            supplied = .init(snapshot: snapshot, result: result, runID: runID)
        } else { supplied = nil }
        let store = ContextManifestStore()
        let builds = ContextManifestBuildCounter696()
        let preparation = ContextManifestBuildCounter696()
        let engine = AgentLoopChatEngine(
            toolExecutor: BuiltinToolExecutor(allowedRoot: root), contextManifestStore: store,
            chatRuntimeDependencies: .init(sessionStore: sessions, memoryStore: memory,
                                           skillStore: skills, soulStore: SoulStore(directory: root.appendingPathComponent("soul"))),
            contextManifestInput: supplied,
            onContextPreparation: { preparation.increment() },
            onContextManifestBuild: { builds.increment() }, composerPolicyFacts: facts
        )
        let mustReject = route == "explicit-foreign" || route == "normal-over-budget"
        do {
            let stream = try await engine.streamReply(
                provider: provider, history: [ChatMessageUI(role: .user, content: "abcdefgh")],
                systemPrompt: route == "normal-over-budget" ? String(repeating: "x", count: 80) : "abcd",
                maxTokens: 1000, conversationID: sessionID,
                authorizedSessionReadSessionID: nil, authorizedSessionReadScope: nil,
                turnID: turn.turnID, composerSnapshot: submission,
                executionIdentity: executionIdentity,
                turnRuntimeSnapshot: ChatTurnRuntimeSnapshot(
                    turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
            )
            for try await _ in stream {}
            #expect(!mustReject)
        } catch let error as AgentLoopChatEngine.ContextManifestConsumptionError {
            #expect(mustReject)
            #expect(error == (route == "explicit-foreign" ? .rejected : .contextLengthExceeded))
        }
        // Retain this exact active SettingsCenter through the asynchronous request.
        #expect(center.contextLengthTokens == 13)
        // Exhausted history is rejected before context preparation begins.
        #expect(preparation.value == (route == "normal-over-budget" ? 0 : 1))
        #expect(builds.value == ((route == "normal" || route == "normal-first-turn-zero") ? 1 : 0))
        let inspectorContext = ChatInspectorContextConsumer.capture(
            store: store, sessionID: sessionID, turnID: turn.turnID,
            executionIdentity: executionIdentity, explicitRunID: supplied?.runID)
        if mustReject {
            #expect(inspectorContext == nil)
            #expect(provider.receivedMaxTokens.isEmpty)
            #expect(provider.receivedHistory.isEmpty)
            #expect(store.manifest(runID: runID) == nil)
            #expect(store.receipt(runID: runID) == nil)
        } else {
            #expect(provider.receivedMaxTokens == [10])
            #expect(provider.receivedHistory.count == 1)
            let receivedHistory = try #require(provider.receivedHistory.first)
            #expect(receivedHistory.last?.content == "abcdefgh")
            let manifest = try #require(store.manifest(runID: runID))
            let receipt = try #require(store.receipt(runID: runID))
            #expect(manifest.snapshot == snapshot)
            let inspector = try #require(inspectorContext)
            #expect(inspector.snapshot == manifest.snapshot)
            #expect(inspector.entries == manifest.entries)
            #expect(inspector.receipt == receipt)
            #expect(inspector.runID == runID && inspector.turnID == turn.turnID)
            let source = ChatInspectorSourceItem(entry: try #require(inspector.entries.first))
            #expect(source.identifier == "system-prompt" && source.provenance == "chat.system")
            #expect(manifest.entries.count == 1)
            let entry = try #require(manifest.entries.first)
            #expect(entry.contentHash == ContextItem.hash(content: "abcd", identifier: "system-prompt"))
            #expect(entry.required)
            #expect(receipt.requestedBudget == 13)
            #expect(receipt.usedBudget == 1)
            #expect(receipt.droppedEntryIDs.isEmpty)
        }
    }

    private static func balancedCallBody(in source: String, marker: String) -> String? {
        guard let markerRange = source.range(of: marker) else { return nil }

        var depth = 1
        var index = markerRange.upperBound
        while index < source.endIndex {
            switch source[index] {
            case "(":
                depth += 1
            case ")":
                depth -= 1
                if depth == 0 {
                    return String(source[markerRange.upperBound..<index])
                }
            default:
                break
            }
            index = source.index(after: index)
        }
        return nil
    }
}
