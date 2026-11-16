import Foundation
import Dispatch
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Context settings frozen before asynchronous turn preparation", .serialized)
@MainActor
struct ContextSettingsAdmission1744Tests {
    private final class CanonicalizationGate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var calls = 0
        private var timedOut = false

        func resolve(_ directory: URL) -> URL {
            lock.lock()
            calls += 1
            let first = calls == 1
            lock.unlock()
            if first {
                entered.signal()
                let result = release.wait(timeout: .now() + .milliseconds(500))
                lock.lock()
                timedOut = result == .timedOut
                lock.unlock()
            }
            return directory.resolvingSymlinksInPath().standardizedFileURL
        }

        var didTimeOut: Bool {
            lock.lock(); defer { lock.unlock() }
            return timedOut
        }

        var callCount: Int {
            lock.lock(); defer { lock.unlock() }
            return calls
        }
    }

    @Test("real turn factory keeps the main actor responsive while verifying its canonical session root")
    func productionTurnCanonicalizationDoesNotBlockMainActor() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "Context2410", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        let settings = center(profile)
        let defaults = profile.makeUserDefaults()
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: settings.logManager,
            workflowStore: WorkflowStore(storeDirectory: profile.rootDirectory.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            canvasRuntimeState: .disabled, agentTaskStore: AgentTaskStore(),
            contextManifestStore: ContextManifestStore(), memoryStore: settings.memoryStore,
            memoryProposalConsumer: settings.memoryProposalConsumer,
            providerReadinessStore: settings.providerReadinessStore,
            taskCenterBindingPersistenceURL: profile.rootDirectory.appendingPathComponent("task-center.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in SpeechToolDirectObservations() }
        )
        await bridge.attachProductionServices(
            agentSettings: settings.settings.agent, fileAccessAllowedRoot: profile.rootDirectory,
            fileAccessDeniedRoots: [], sessionDirectory: profile.sessionDirectory,
            mcpManager: settings.mcpManager, skillStore: settings.skillStore,
            canvasRuntimeState: .disabled, externalRunners: [:], externalNetworkAllowed: false
        ).value
        let gate = CanonicalizationGate()
        bridge.contextDirectoryCanonicalizerForTests = { gate.resolve($0) }
        DispatchQueue.global(qos: .userInitiated).async {
            guard gate.entered.wait(timeout: .now() + .seconds(2)) == .success else { return }
            Task { @MainActor in gate.release.signal() }
        }
        let factory = try #require(bridge.chat.turnRuntimeSnapshotFactory)
        let sessionID = try #require(bridge.chat.activeSessionID?.uuidString)
        let turn = AgentTurnIdentity(sessionID: sessionID, turnID: 1, messageID: "context2410:assistant")
        let pending = factory(turn, MockProvider.shared)
        let prepared = try #require(await pending.preparedForExecution())
        #expect(gate.callCount > 0)
        #expect(!gate.didTimeOut, "the canonical root probe blocked the main actor heartbeat")
        guard case .accepted? = prepared.contextSettingsCapture?.resolution else {
            Issue.record("the same-root production turn lost its settings admission")
            return
        }
    }

    @Test("a symlink retargeted after turn capture cannot become the admitted session root")
    func deferredTurnRejectsRetargetedSessionDirectory() async throws {
        let first = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "Context2410A", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        let second = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "Context2410B", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        let owner = center(first)
        let alias = first.rootDirectory.appendingPathComponent("session-alias")
        try FileManager.default.createSymbolicLink(at: alias,
            withDestinationURL: first.sessionDirectory)
        let aliasedStore = SessionStore(directory: alias)
        let expected = first.sessionDirectory.resolvingSymlinksInPath().standardizedFileURL
        let pending = ChatContextSettingsCapture.deferredForProduction(
            sessionStore: aliasedStore, sessionID: "synthetic-retarget-2410",
            model: MockProvider.shared.model, expectedCanonicalDirectory: expected,
            canonicalizeDirectory: { $0.resolvingSymlinksInPath().standardizedFileURL }
        )
        #expect(owner.sessionStore.directory == first.sessionDirectory)
        guard case .scopeMismatch = pending.resolution else {
            Issue.record("Unprepared production directory may not be admitted")
            return
        }
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias,
            withDestinationURL: second.sessionDirectory)
        let prepared = try #require(await pending.preparedForExecution())
        guard case .scopeMismatch = prepared.resolution else {
            Issue.record("A changed symlink target inherited the old turn's session root")
            return
        }
    }

    private func center(_ profile: RuntimeIsolationProfile) -> SettingsCenter {
        let keychain = profile.makeKeychainStore()
        return SettingsCenter(
            settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: EnvVarStore(directory: profile.providerConfigurationDirectory, keychain: keychain),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            memoryFileStore: MemoryFileStore(directory: profile.rootDirectory.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            logManager: profile.makeLogManager(),
            mcpManager: MCPServerManager(fileURL: profile.mcpDirectory.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: profile.providerConfigurationDirectory)
        )
    }

    private func accepted(_ runtime: ChatTurnRuntimeSnapshot) throws -> ContextTurnSettingsSnapshot {
        guard case .accepted(let snapshot)? = runtime.contextSettingsCapture?.resolution else {
            Issue.record("Production factory did not freeze accepted context settings")
            throw CocoaError(.coderInvalidValue)
        }
        return snapshot
    }

    @Test("production admission survives settings edits, async preparation and same-profile rebind")
    func admittedRevisionFeedsActualRequestsAfterSettingsRebind() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "Context1744", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        let defaults = profile.makeUserDefaults()
        // Retain only this owned synthetic fixture for any failed assertion.
        let firstCenter = center(profile)
        #expect(firstCenter.setContextLengthTokens(6_144))
        #expect(firstCenter.setHistoryTurnLimit(2))
        let manifests = ContextManifestStore()
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: firstCenter.logManager,
            workflowStore: WorkflowStore(storeDirectory: profile.rootDirectory.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            canvasRuntimeState: .disabled, agentTaskStore: AgentTaskStore(),
            contextManifestStore: manifests, memoryStore: firstCenter.memoryStore,
            memoryProposalConsumer: firstCenter.memoryProposalConsumer,
            providerReadinessStore: firstCenter.providerReadinessStore,
            taskCenterBindingPersistenceURL: profile.rootDirectory.appendingPathComponent("task-center.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
            }
        )
        await bridge.attachProductionServices(
            agentSettings: firstCenter.settings.agent, fileAccessAllowedRoot: profile.rootDirectory,
            fileAccessDeniedRoots: [], sessionDirectory: profile.sessionDirectory,
            mcpManager: firstCenter.mcpManager, skillStore: firstCenter.skillStore,
            canvasRuntimeState: .disabled, externalRunners: [:], externalNetworkAllowed: false
        ).value
        let sessions = try #require(bridge.chat.sessionStore)
        let sessionID = bridge.chat.applyNewSession(title: "context1744").uuidString
        for message in [LLMMessage(role: .user, content: "old-user1744"),
                        LLMMessage(role: .assistant, content: "old-assistant1744"),
                        LLMMessage(role: .user, content: "current-user1744")] {
            try sessions.saveMessage(message, sessionID: sessionID)
        }
        let recorder = M03ContextRequestRecorder()
        let provider = M03ContextRecordingProvider(recorder: recorder)
        let firstTurn = AgentTurnIdentity(sessionID: sessionID, turnID: 1, messageID: "assistant:1")
        let factory = try #require(bridge.chat.turnRuntimeSnapshotFactory)
        let pending = factory(firstTurn, provider).withEffectiveSettings(
            nil, operationID: "context1744:first", required: false)
        guard case .scopeMismatch? = pending.contextSettingsCapture?.resolution else {
            Issue.record("Unprepared production capture must fail closed")
            return
        }

        // The turn has crossed the real production factory, but has not yet
        // prepared skills/route or reached the engine. This is the old gap.
        #expect(firstCenter.setContextLengthTokens(1_024))
        #expect(firstCenter.setHistoryTurnLimit(1))
        let reopened = center(profile)
        #expect(reopened.contextLengthTokens == 1_024 && reopened.historyTurnLimit == 1)
        await bridge.attachProductionServices(
            agentSettings: reopened.settings.agent, fileAccessAllowedRoot: profile.rootDirectory,
            fileAccessDeniedRoots: [], sessionDirectory: profile.sessionDirectory,
            mcpManager: reopened.mcpManager, skillStore: reopened.skillStore,
            canvasRuntimeState: .disabled, externalRunners: [:], externalNetworkAllowed: false
        ).value
        let prepared = try #require(await pending.preparedForExecution())
        let before = try accepted(prepared)
        let secondTurn = AgentTurnIdentity(sessionID: sessionID, turnID: 2, messageID: "assistant:2")
        let nextFactory = try #require(bridge.chat.turnRuntimeSnapshotFactory)
        let next = nextFactory(secondTurn, provider)
        let nextPrepared = try #require(await next.preparedForExecution())
        let after = try accepted(nextPrepared)
        #expect(before.revision != after.revision)
        #expect(before.contextLengthTokens == 6_144 && before.historyTurnLimit == 2)
        #expect(after.contextLengthTokens == 1_024 && after.historyTurnLimit == 1)

        let facts = ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: "context1744", revision: "synthetic-policy", grantEpoch: "synthetic-epoch",
            leaseID: "synthetic-lease", expiresAt: Date().addingTimeInterval(300), autonomyCeiling: .l3)
        let engine = AgentLoopChatEngine(
            contextManifestStore: manifests,
            chatRuntimeDependencies: .init(sessionStore: sessions, memoryStore: reopened.memoryStore,
                skillStore: reopened.skillStore,
                soulStore: SoulStore(directory: profile.rootDirectory.appendingPathComponent("soul"))),
            composerPolicyFacts: facts)
        var admittedIdentities: [Int: AgentExecutionIdentity] = [:]
        for captured in [prepared, nextPrepared] {
            let turn = captured.turn
            // Exercise the actual AgentLoop with an offline recording provider.
            // Route authorization is independent of the context contract; this
            // fixture does not promote the production factory's denied route.
            let runtime = ChatTurnRuntimeSnapshot(turn: turn,
                skillInjector: SkillInjector(store: reopened.skillStore).snapshotForTurn(), mcpBridge: nil,
                contextSettingsCapture: captured.contextSettingsCapture)
            let composer = ComposerSubmissionSnapshot(
                mode: .auto, approvalScope: .request, effort: .standard,
                sessionID: sessionID, turnID: turn.turnID, taskID: "task:\(turn.turnID)",
                attemptID: "attempt:\(turn.turnID)", messageID: turn.messageID,
                inputDigest: "digest:\(turn.turnID)", workspaceID: facts.workspaceID, createdAt: Date(),
                policyRevision: facts.revision, grantEpoch: facts.grantEpoch, autonomyCeiling: .l3)
            let identity = AgentExecutionIdentity(turn: turn)
            admittedIdentities[turn.turnID] = identity
            let stream = try await engine.streamReply(provider: provider,
                history: [ChatMessageUI(role: .user, content: "stale-view1744")],
                systemPrompt: "synthetic-system", maxTokens: 4_096, conversationID: sessionID,
                authorizedSessionReadSessionID: nil, authorizedSessionReadScope: nil,
                turnID: turn.turnID, composerSnapshot: composer,
                executionIdentity: identity, turnRuntimeSnapshot: runtime)
            for try await _ in stream {}
        }
        let calls = await recorder.recorded()
        #expect(calls.count == 2)
        guard calls.count == 2 else { return }
        #expect(calls[0].contents.contains("old-user1744"))
        #expect(calls[0].contents.contains("old-assistant1744"))
        #expect(calls[0].maxTokens == 4_096)
        #expect(!calls[1].contents.contains("old-user1744"))
        #expect(!calls[1].contents.contains("old-assistant1744"))
        #expect(calls[1].contents.contains("current-user1744"))
        #expect(calls[1].maxTokens > 0 && calls[1].maxTokens < 1_024)
        #expect(!calls.flatMap(\.contents).contains("stale-view1744"))
        for (turn, settings) in [(firstTurn, before), (secondTurn, after)] {
            // Retain the exact admitted operation/attempt, including the
            // generated operation ID, rather than rebuilding a display ID.
            let identity = try #require(admittedIdentities[turn.turnID])
            let runID = try AgentLoopChatEngine.generatedContextManifestRunID(for: identity)
            let manifest = try #require(manifests.manifest(runID: runID))
            #expect(manifest.snapshot.configurationFingerprint.hasSuffix(settings.revision))
            #expect(manifests.receipt(runID: runID)?.requestedBudget == settings.contextLengthTokens)
        }
        #expect(sessions.loadSession(id: sessionID)?.messages.prefix(3).map(\.content)
                == ["old-user1744", "old-assistant1744", "current-user1744"])
    }

    @Test("a captured revision cannot cross a session-directory rebind even with the same session ID")
    func capturedSettingsRefuseDifferentCanonicalDirectory() async throws {
        let first = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "Context1744A", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        let oldOwner = center(first)
        #expect(oldOwner.setContextLengthTokens(1_024))
        let recorder = M03ContextRequestRecorder()
        let provider = M03ContextRecordingProvider(recorder: recorder)
        let turn = AgentTurnIdentity(sessionID: "same-context1744", turnID: 1, messageID: "assistant:1")
        let captured = ChatContextSettingsCapture(
            sessionStore: oldOwner.sessionStore, sessionID: turn.sessionID, model: provider.model)
        let second = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "Context1744B", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        let newOwner = center(second)
        #expect(newOwner.setContextLengthTokens(1_024))
        _ = try newOwner.sessionStore.createSession(id: turn.sessionID)
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: "context1744", revision: "synthetic-policy", grantEpoch: "synthetic-epoch",
            leaseID: "synthetic-lease", expiresAt: Date().addingTimeInterval(300), autonomyCeiling: .l3)
        let engine = AgentLoopChatEngine(chatRuntimeDependencies: .init(
            sessionStore: newOwner.sessionStore, memoryStore: newOwner.memoryStore,
            skillStore: newOwner.skillStore,
            soulStore: SoulStore(directory: second.rootDirectory.appendingPathComponent("soul"))),
            composerPolicyFacts: facts)
        let runtime = ChatTurnRuntimeSnapshot(turn: turn,
            skillInjector: SkillInjector(store: newOwner.skillStore).snapshotForTurn(), mcpBridge: nil,
            contextSettingsCapture: captured)
        let composer = ComposerSubmissionSnapshot(
            mode: .auto, approvalScope: .request, effort: .standard,
            sessionID: turn.sessionID, turnID: turn.turnID, taskID: "task:1", attemptID: "attempt:1",
            messageID: turn.messageID, inputDigest: "digest:1", workspaceID: facts.workspaceID,
            createdAt: Date(), policyRevision: facts.revision, grantEpoch: facts.grantEpoch, autonomyCeiling: .l3)
        do {
            _ = try await engine.streamReply(provider: provider, history: [],
                systemPrompt: "synthetic-system", maxTokens: 512, conversationID: turn.sessionID,
                authorizedSessionReadSessionID: nil, authorizedSessionReadScope: nil,
                turnID: turn.turnID, composerSnapshot: composer,
                executionIdentity: AgentExecutionIdentity(turn: turn), turnRuntimeSnapshot: runtime)
            Issue.record("A different canonical directory accepted the old revision")
        } catch AgentLoopChatEngine.ContextManifestConsumptionError.contextSettingsScopeMismatch {
            // This is the existing fail-closed scope error, not a new authority.
        }
        #expect(await recorder.recorded().isEmpty)
    }
}
