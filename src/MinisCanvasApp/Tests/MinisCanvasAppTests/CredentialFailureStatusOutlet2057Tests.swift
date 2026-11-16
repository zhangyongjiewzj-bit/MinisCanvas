import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private struct CredentialEchoFailure2057: LocalizedError, Sendable {
    let echoedValue: String
    var errorDescription: String? { "离线 Provider 失败，诊断 " + echoedValue }
}

private final class CredentialFailureProvider2057: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "credi-failure-fixture"
    var model = LLMModel(id: "credi-failure-model", displayName: "CREDI Failure", provider: "credi-failure-fixture")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "credi-failure-synthetic"
    let secret: String

    let observationCase: String

    init(secret: String, observationCase: String) {
        self.secret = secret
        self.observationCase = observationCase
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        print("CREDENTIAL2057_PROVIDER case=\(observationCase) method=send phase=throw error_type=CredentialEchoFailure2057")
        throw CredentialEchoFailure2057(echoedValue: secret)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        print("CREDENTIAL2057_PROVIDER case=\(observationCase) method=send-with-tools phase=throw error_type=CredentialEchoFailure2057")
        throw CredentialEchoFailure2057(echoedValue: secret)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        print("CREDENTIAL2057_PROVIDER case=\(observationCase) method=stream phase=throw error_type=CredentialEchoFailure2057")
        throw CredentialEchoFailure2057(echoedValue: secret)
    }
}

@Suite("D-CREDI actual Provider failure status outlets", .serialized)
@MainActor
struct CredentialFailureStatusOutlet2057Tests {
    @Test func knownCredentialInProviderFailureIsAbsentFromStructuredRetryEnvelope() async throws {
        let (center, backing, root) = try CredentialTestSupport.makeCenter()
        defer { try? FileManager.default.removeItem(at: root) }
        let broker = ChatCredentialBroker()
        broker.attach(center: center, externalNetworkAllowed: false)
        let secret = "CREDI-RECEIPT-OPAQUE-" + UUID().uuidString
        let sessionID = "credi-receipt-session"
        let provider = CredentialFailureProvider2057(secret: secret, observationCase: "structured")
        defer { withExtendedLifetime(center) {} }
        // Freeze this real owner before credential confirmation can suspend.
        let settingsCapture = ChatContextSettingsCapture(
            sessionStore: center.sessionStore, sessionID: sessionID, model: provider.model
        )
        let custodySession = UUID()
        let request = try #require(broker.captureSecureField(secret, sessionID: custodySession))
        #expect(await CredentialTestSupport.confirm(broker, request: request) == .savedProbeBlocked)
        #expect(backing.get("SYNTHETIC_BROKER_API_KEY") == secret)

        let turnID = 1
        let history = ChatMessageUI(role: .user, content: "ordinary public request")
        _ = try center.sessionStore.createSession(id: sessionID, projectID: "credi-public-project")
        try center.sessionStore.saveMessage(history.asLLMMessage(), sessionID: sessionID)
        let providerSnapshot = try ProviderRuntimeSnapshot(
            providerID: provider.model.provider, modelID: provider.model.id,
            readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
            applyReceiptID: "provider-readiness-apply:credi-2057")
        let route = try ProviderRuntimeRoute(snapshot: providerSnapshot, primary: provider)
        let turn = AgentTurnIdentity(sessionID: sessionID, turnID: turnID, messageID: "credi-receipt-message")
        let turnSnapshot = ChatTurnRuntimeSnapshot(turn: turn,
            skillInjector: SkillInjector(store: SkillStore(skillsRoot: root.appendingPathComponent("skills")))
                .snapshotForTurn(),
            mcpBridge: nil, providerRuntimeRoute: route, requiresProviderRuntimeRoute: true,
            contextSettingsCapture: settingsCapture)
        let composer = ComposerSubmissionSnapshot(
            mode: .auto, approvalScope: .request, effort: .standard,
            sessionID: sessionID, turnID: turnID, taskID: "credi-receipt-task",
            attemptID: "credi-receipt-attempt", messageID: turn.messageID,
            inputDigest: "credi-public-input", workspaceID: "credi-receipt-workspace",
            createdAt: Date(), policyRevision: "credi-receipt-policy",
            grantEpoch: "credi-receipt-grant", autonomyCeiling: .l3)
        let execution = AgentExecutionIdentity(turn: turn, operationID: "credi-receipt-operation", attempt: 1)
        let engine = AgentLoopChatEngine(
            toolExecutor: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []),
            chatRuntimeDependencies: .init(
                sessionStore: center.sessionStore,
                memoryStore: center.memoryStore,
                skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
                soulStore: SoulStore(directory: root.appendingPathComponent("soul"))),
            contextWritebackStorePersistenceURL: root.appendingPathComponent("context.json"),
            composerPolicyFacts: ComposerPolicyFactSource(
                knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
                workspaceID: "credi-receipt-workspace", revision: "credi-receipt-policy",
                grantEpoch: "credi-receipt-grant", leaseID: "credi-receipt-lease",
                expiresAt: .distantFuture, autonomyCeiling: .l3)
        ).withToolResultProjection { output in await broker.protect(output) }
        let stream = try await engine.streamReply(
            provider: provider, history: [history], systemPrompt: "public system prompt",
            maxTokens: 128, conversationID: sessionID,
            authorizedSessionReadSessionID: nil, authorizedSessionReadScope: nil,
            turnID: turnID, composerSnapshot: composer,
            executionIdentity: execution, turnRuntimeSnapshot: turnSnapshot)
        do {
            for try await _ in stream {}
            Issue.record("expected a structured retry failure")
        } catch let error as ChatSessionRuntimeError {
            guard case .turnFailed(let envelope) = error else {
                Issue.record("unexpected retry failure kind: \(error)")
                return
            }
            let encoded = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
            #expect(envelope.failureMessage.contains("离线 Provider 失败"))
            #expect(!envelope.failureMessage.contains(secret))
            #expect(envelope.failureMessage.contains(ContentSecretRedactor.mask(secret)))
            #expect(!encoded.contains(secret))
            #expect(envelope.inputText.contains("ordinary public request"))
        }
    }

    @Test func knownCredentialInProviderFailureIsAbsentFromSidebarAndDurableExecutionState() async throws {
        let (center, backing, root) = try CredentialTestSupport.makeCenter()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsDomain = "credi-failure-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsDomain))
        defer { defaults.removePersistentDomain(forName: defaultsDomain) }
        let chat = ChatStore(preferencesDefaults: defaults, logManager: center.logManager)
        try #require(chat.attachPersistence(center.sessionStore))
        chat.applyNewSession(title: "Credential sidebar production fixture",
            projectID: "credi-sidebar-project", projectName: "Synthetic credential project",
            workingDirectory: root.path)
        let sessionID = try #require(chat.activeSessionID)
        let secret = "CREDI-ERROR-OPAQUE-" + UUID().uuidString
        let provider = CredentialFailureProvider2057(secret: secret, observationCase: "sidebar")
        defer { withExtendedLifetime(center) {} }
        let settingsCapture = ChatContextSettingsCapture(
            sessionStore: center.sessionStore, sessionID: sessionID.uuidString, model: provider.model
        )
        chat.credentialBroker.attach(center: center, externalNetworkAllowed: false)
        let request = try #require(chat.credentialBroker.captureSecureField(secret, sessionID: sessionID))
        #expect(await CredentialTestSupport.confirm(chat.credentialBroker, request: request) == .savedProbeBlocked)
        #expect(backing.get("SYNTHETIC_BROKER_API_KEY") == secret)

        let providerSnapshot = try ProviderRuntimeSnapshot(
            providerID: provider.model.provider, modelID: provider.model.id,
            readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
            applyReceiptID: "provider-readiness-apply:credi-2057")
        let route = try ProviderRuntimeRoute(snapshot: providerSnapshot, primary: provider)
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(turn: turn,
                skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil,
                providerRuntimeRoute: route, requiresProviderRuntimeRoute: true,
                contextSettingsCapture: settingsCapture)
        }
        let facts = ComposerPolicyFactSource(
            knownCapabilities: ["file_read"], grantedCapabilities: ["file_read"],
            allowedWriteRoots: [root.path], workspaceID: chat.composerWorkspaceID,
            revision: "credi-failure-policy", grantEpoch: "credi-failure-epoch",
            leaseID: "credi-failure-lease", expiresAt: .distantFuture,
            autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = .init(mode: .auto, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        chat.agentEngine = AgentLoopChatEngine(
            toolExecutor: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []),
            requestBudget: chat.budgetTracker,
            chatRuntimeDependencies: .init(
                sessionStore: center.sessionStore,
                memoryStore: center.memoryStore,
                skillStore: skills,
                soulStore: SoulStore(directory: root.appendingPathComponent("soul"))),
            contextWritebackStorePersistenceURL: center.sessionStore.directory
                .appendingPathComponent("agent-turn-context-v1.json"),
            toolExecutionFactLedger: try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json")),
            composerPolicyFacts: facts,
            onRetryLifecycleEvent: { event in
                print("CREDENTIAL2057_RETRY case=sidebar phase=\(event.rawValue)")
            })
        chat.streamingProviderOverride = provider
        chat.draftText = "请回答普通问题。"
        chat.submitComposer()
        let deadline = Date().addingTimeInterval(15)
        while chat.isStreaming && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!chat.isStreaming)

        let status = try #require(chat.executionSnapshot(forSessionID: sessionID))
        let item = try #require(chat.sessionList.first(where: { $0.session.id == sessionID }))
        let disk = try String(contentsOf: center.sessionStore.directory.appendingPathComponent("chat-execution-state.json"),
                              encoding: .utf8)
        #expect(chat.messages.last?.content.contains(secret) == false)
        #expect(status.failureReason?.contains("离线 Provider 失败") == true)
        #expect(status.failureReason?.contains(secret) == false)
        #expect(!item.indicator.helpText.contains(secret))
        #expect(item.indicator.helpText.contains(ContentSecretRedactor.mask(secret)))
        #expect(!disk.contains(secret))
        #expect(disk.contains("离线 Provider 失败"))
        let restarted = ChatStore(preferencesDefaults: defaults, logManager: center.logManager)
        try #require(restarted.attachPersistence(center.sessionStore))
        let restored = try #require(restarted.executionSnapshot(forSessionID: sessionID))
        #expect(restored.failureReason?.contains(secret) == false)
        #expect(restarted.sessionList.first(where: { $0.session.id == sessionID })?.indicator.helpText.contains(secret) == false)
        chat.stopAllStreamingForSafety()
    }
}
