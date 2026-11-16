import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Logical document continuity at the actual ChatStore -> transcript cache
/// boundary. Does not measure displayed frames, layout or native view mounting.
@Suite("PERF02 production placeholder and session document continuity", .serialized)
@MainActor
struct TranscriptProductionTransition2830Tests {
    @Test func heldProductionReplyKeepsHistoryThroughPlaceholderSwitchAndDurableReturn() async throws {
        let fixture = try Fixture()
        let provider = HeldReply()
        let chat = fixture.bridge.chat
        await fixture.attach()
        chat.streamingProviderOverride = provider
        defer { provider.release(); chat.stopAllStreamingForSafety() }
        do {
            try await exercise(fixture, provider)
        } catch {
            provider.release()
            chat.stopAllStreamingForSafety()
            #expect(await waitUntil { provider.active == 0 && !chat.hasStreamingTasksForSafety },
                    "failed oracle must drain its owned producer")
            throw error
        }
        provider.release()
        #expect(await waitUntil { provider.active == 0 && !chat.hasStreamingTasksForSafety },
                "physical producer and production consumer must finish")
    }

    private func exercise(_ fixture: Fixture, _ provider: HeldReply) async throws {
        await ChatTranscriptStatusIconProjection.preload()
        let chat = fixture.bridge.chat
        let cache = ChatTranscriptDocumentCache()
        let redactor = ChatTranscriptRedactor(secretValues: [])
        func render() -> String {
            cache.render(sessionID: chat.activeSessionID, messages: chat.messages,
                         baseSize: 13, redactor: redactor).attributedString.string
        }
        let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        #expect(chat.providerRuntimeRouteFactory != nil)
        #expect(chat.turnRuntimeSnapshotFactory != nil)
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        let before = render()
        #expect(before.contains("A_HISTORY_2830") && before.contains("A_ANSWER_2830"))
        let initialGeneration = cache.update.generation
        chat.draftText = "A_SEND_2830"
        chat.submitComposer()
        let entered = await waitUntil { provider.calls == 1 && provider.active == 1 }
        #expect(entered, "actual factory/AgentLoop must reach the controlled local producer")
        guard entered else { throw CocoaError(.coderInvalidValue) }
        let source = provider.source
        #expect(source.contains { $0.content == "A_HISTORY_2830" })
        #expect(source.contains { $0.content == "A_SEND_2830" })
        #expect(!source.contains { $0.content.contains("B_HISTORY_2830") })
        let placeholder = try #require(chat.messages.last)
        #expect(placeholder.role == .assistant && placeholder.isStreaming && placeholder.content.isEmpty)
        let during = render()
        #expect(during.contains("A_HISTORY_2830") && during.contains("A_ANSWER_2830"))
        #expect(during.contains("A_SEND_2830"))
        #expect(during.contains("\u{FFFC}") && during.contains("生成中…"))
        #expect(cache.update.generation == initialGeneration, "append must retain the historical document generation")
        #expect(!ChatTranscriptFormatter.plainText(chat.messages).contains(ChatTranscriptFormatter.streamingPlaceholder))
        let assistantID = placeholder.id
        let bBefore = try #require(fixture.settings.sessionStore.loadSession(id: fixture.otherSessionID.uuidString))

        // Real session pointer transitions, while A's actual provider remains
        // held. Cache receives the same active store projection as the view.
        #expect(chat.applySwitchSession(id: fixture.otherSessionID))
        let bVisible = render()
        #expect(!bVisible.isEmpty && bVisible.contains("B_HISTORY_2830") && bVisible.contains("B_ANSWER_2830"))
        #expect(!bVisible.contains("A_HISTORY_2830") && !bVisible.contains("A_SEND_2830"))
        #expect(!bVisible.contains("\u{FFFC}") && !bVisible.contains("生成中…"))
        #expect(provider.active == 1)
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        let returnedPending = render()
        #expect(returnedPending == during, "return must retain A's existing history and identical pending placeholder")
        #expect(chat.messages.last?.id == assistantID)
        #expect(chat.applySwitchSession(id: fixture.otherSessionID))
        #expect(render() == bVisible)

        provider.release()
        let settled = await waitUntil { provider.exits == 1 && provider.active == 0 && !chat.hasStreamingTasksForSafety }
        #expect(settled, "owned physical reply exit and original consumer settlement must both occur")
        guard settled else { throw CocoaError(.coderInvalidValue) }
        #expect(chat.activeSessionID == fixture.otherSessionID)
        #expect(render() == bVisible, "A's late physical reply must not blank or replace B's document")
        #expect(fixture.settings.sessionStore.loadSession(id: fixture.otherSessionID.uuidString) == bBefore)
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        let completed = render()
        #expect(completed.contains("A_HISTORY_2830") && completed.contains("A_ANSWER_2830"))
        #expect(completed.contains("A_SEND_2830") && completed.contains("A_REPLY_2830"))
        #expect(!completed.contains("\u{FFFC}") && !completed.contains("生成中…"))
        #expect(chat.messages.last?.id == assistantID)
        #expect(chat.messages.last?.isStreaming == false)
        #expect(provider.calls == 1 && provider.exits == 1)
        #expect(fixture.bridge.providerRuntimeObservations.count == 1)
        #expect(engine.toolExecutionFactLedger.facts.isEmpty)
        let reopened = SessionStore(directory: fixture.profile.sessionDirectory)
        let aDurable = try #require(reopened.loadSession(id: fixture.sessionID.uuidString))
        #expect(aDurable.messages.map(\.content) == ["A_HISTORY_2830", "A_ANSWER_2830", "A_SEND_2830", "A_REPLY_2830"])
        #expect(reopened.loadSession(id: fixture.otherSessionID.uuidString) == bBefore)
        #expect(!aDurable.messages.contains { $0.content.contains(ChatTranscriptFormatter.streamingPlaceholder) })
        print("PERF2830 logicalProjectionSteps=6 actualRequests=1 physicalExits=1 displayedFrames=NOT_OBSERVED")
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    @MainActor private final class Fixture {
        let profile: RuntimeIsolationProfile
        let settings: SettingsCenter
        let bridge: BridgeStore
        let sessionID = UUID()
        let otherSessionID = UUID()

        init() throws {
            profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "Compaction2830",
                processEnvironment: [:], processArguments: ["MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
            let defaults = profile.makeUserDefaults()
            let keychain = profile.makeKeychainStore()
            let sessions = SessionStore(directory: profile.sessionDirectory)
            let a = [LLMMessage(role: .user, content: "A_HISTORY_2830"),
                     LLMMessage(role: .assistant, content: "A_ANSWER_2830")]
            let b = [LLMMessage(role: .user, content: "B_HISTORY_2830"),
                     LLMMessage(role: .assistant, content: "B_ANSWER_2830")]
            try sessions.updateSession(ChatSession(id: sessionID.uuidString, title: "Owned A2830", messages: a))
            try sessions.updateSession(ChatSession(id: otherSessionID.uuidString, title: "Owned B2830", messages: b))
            let badges = SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges"))
            let readiness = ProviderReadinessStore(directory: profile.providerConfigurationDirectory)
            let accepted = readiness.upsert([ProviderReadinessPersistenceRecord(
                providerID: HeldReply.providerID, modelID: HeldReply.modelID, status: .passed, readinessState: .mock,
                checkedAt: Date(timeIntervalSince1970: 1_000), evidenceID: "readiness2830", isApplied: true,
                discoveryReceiptID: "discovery2830", discoveredAt: Date(timeIntervalSince1970: 1_000),
                applyReceiptID: "provider-readiness-apply:2830", appliedAt: Date(timeIntervalSince1970: 1_001))])
            guard accepted else { throw CocoaError(.fileWriteUnknown) }
            let shortcuts = ShortcutStore(defaults: defaults)
            settings = SettingsCenter(settingsStore: SettingsStore(directory: profile.settingsDirectory),
                envStore: EnvVarStore(directory: profile.providerConfigurationDirectory, keychain: keychain,
                    privacyStore: EnvVarPrivacyStore(defaults: defaults)),
                memoryStore: MemoryStore(directory: profile.memoryDirectory),
                memoryFileStore: MemoryFileStore(directory: profile.rootDirectory.appendingPathComponent("memory-files")),
                sessionStore: sessions, sessionBadgeStore: badges, logManager: profile.makeLogManager(),
                mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
                skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")),
                usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain), shortcutStore: shortcuts,
                providerReadinessTransport: FailClosedProviderReadinessTransport(), providerReadinessDeployment: .mock,
                providerReadinessStore: readiness)
            bridge = BridgeStore(shortcutStore: shortcuts, preferencesDefaults: defaults,
                logManager: settings.logManager,
                workflowStore: WorkflowStore(storeDirectory: profile.rootDirectory.appendingPathComponent("workflows")),
                sessionBadgeStore: badges, sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
                canvasRuntimeState: .disabled,
                agentTaskStore: try AgentTaskStore(persistenceURL: profile.rootDirectory.appendingPathComponent("tasks2830.json")),
                contextManifestStore: try ContextManifestStore(persistenceURL: profile.rootDirectory.appendingPathComponent("manifest2830.json")),
                memoryStore: settings.memoryStore, memoryProposalConsumer: settings.memoryProposalConsumer,
                providerReadinessStore: readiness,
                taskCenterBindingPersistenceURL: profile.rootDirectory.appendingPathComponent("task-center2830.json"),
                canvasFeatureLane: .phase3NonCanvas,
                speechToolDirectObservationProvider: { _ in SpeechToolDirectObservations() })
            #expect(bridge.chat.attachPersistence(sessions, badgeStore: badges))
            let owner = settings
            bridge.bindProductionEffectiveSettingsSource { [weak owner] in owner?.bl6EffectiveSettingsSnapshot }
            bridge.chat.restoreComposerPolicy(settings.settings.agent.composerPolicy)
        }
        func attach() async {
            await bridge.attachProductionServices(agentSettings: settings.settings.agent,
                fileAccessAllowedRoot: profile.rootDirectory, fileAccessDeniedRoots: [],
                sessionDirectory: profile.sessionDirectory, mcpManager: settings.mcpManager,
                skillStore: settings.skillStore, canvasRuntimeState: .disabled, externalRunners: [:],
                externalNetworkAllowed: true, sessionReadSecretStore: settings.envStore).value
        }
    }

    private final class HeldReply: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
        static let providerID = "reply2830"
        static let modelID = "reply-model2830"
        let name = HeldReply.providerID
        var model = LLMModel(id: HeldReply.modelID, displayName: "Owned reply", provider: HeldReply.providerID)
        var runtimeConfigurationMaterial: String? = "owned-runtime2830"
        let capabilities: Set<ProviderCapability> = [.tools]
        private let lock = NSLock()
        private var entered = 0
        private var activeCount = 0
        private var exited = 0
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var captured: [LLMMessage] = []
        var calls: Int { lock.withLock { entered } }
        var active: Int { lock.withLock { activeCount } }
        var exits: Int { lock.withLock { exited } }
        var source: [LLMMessage] { lock.withLock { captured } }
        func release() {
            let pending = lock.withLock {
                released = true
                let pending = waiter
                waiter = nil
                return pending
            }
            pending?.resume()
        }
        func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
            lock.withLock { entered += 1; activeCount += 1; captured = messages }
            defer { lock.withLock { activeCount -= 1; exited += 1 } }
            await withCheckedContinuation { continuation in
                let resume = lock.withLock {
                    if released { return true }
                    waiter = continuation
                    return false
                }
                if resume { continuation.resume() }
            }
            return LLMResponse(text: "A_REPLY_2830", stopReason: "stop", usage: nil)
        }
        func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
            try await sendMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
        }
        func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
            throw LLMError.unsupportedCapability(.streaming)
        }
    }
}
