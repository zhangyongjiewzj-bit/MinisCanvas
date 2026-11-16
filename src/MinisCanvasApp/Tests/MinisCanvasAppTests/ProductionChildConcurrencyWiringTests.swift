import Foundation
import CryptoKit
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Production child concurrency wiring")
@MainActor
struct ProductionChildConcurrencyWiringTests {
    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    @Test("BridgeStore forwards effective child concurrency without using tool limit")
    func productionConsumerUsesEffectiveChildSelection() async throws {
        let selection = try ChildConcurrencySelection(
            userSelected: 40,
            recommended: 12,
            effective: 8,
            enabledSessionCount: 5
        )
        let bridge = BridgeStore()
        await bridge.attachProductionServices(
            agentSettings: AgentSettings(concurrentToolLimit: 1),
            enableOrchestration: true,
            childConcurrencySelection: selection
        ).value
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let composite = try #require(findComposite(in: engine.composedExecutor))
        let orchestrator = composite.orchestration.orchestrator

        #expect(orchestrator.childConcurrencySelection == selection)
        #expect(orchestrator.childConcurrencySelection.effective == 8)
        #expect(orchestrator.defaultMaxConcurrent == 8)
        #expect(selection.globalRequestedCapacity == 200)
        #expect(selection.effective <= selection.userSelected)
    }

    @Test("composition rebinds the validated SettingsCenter selection")
    func compositionRebindsLiveSelection() async throws {
        let settingsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("child40-composition-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: settingsRoot) }
        let settings = SettingsCenter(
            settingsStore: SettingsStore(directory: settingsRoot.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: settingsRoot.appendingPathComponent("env")),
            memoryStore: MemoryStore(directory: settingsRoot.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: settingsRoot.appendingPathComponent("sessions"))
        )
        let bridge = BridgeStore()
        bridge.attachProductionServices(enableOrchestration: true)
        ProductionOrchestrationDefaults.bindChildConcurrencySelection(
            to: bridge,
            settings: settings,
            profile: .production
        )

        settings.childConcurrencyUserSelected = 12
        await bridge.lastChildGovernorSafetyTask?.value
        #expect(bridge.childConcurrencySelection.userSelected == 12)
        #expect(bridge.childConcurrencySelection.effective == settings.childConcurrencyEffective)

        settings.childConcurrencyRiskAcknowledged = true
        await bridge.lastChildGovernorSafetyTask?.value
        #expect(bridge.childConcurrencySelection.userSelected == 12)
        #expect(bridge.childConcurrencySelection.effective == 12)
        #expect(bridge.childConcurrencySelection.effective <= ChildConcurrencySelection.hardMaximum)
    }

    @Test("Task Center runtime values follow the shared governor rather than a startup snapshot")
    func liveSharedGovernorProjection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("child-report-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let selection = try ChildConcurrencySelection(userSelected: 1,
            recommended: 1, effective: 1)
        let bridge = BridgeStore()
        bridge.attachProductionServices(fileAccessAllowedRoot: root,
            sessionDirectory: root, enableOrchestration: true,
            childConcurrencySelection: selection)
        let governor = try #require(bridge.orchestrationChildGovernor)
        let revision = try #require(bridge.childGovernorControlRevision)
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let composite = try #require(findComposite(in: engine.composedExecutor))
        #expect(composite.orchestration.orchestrator.childGovernor === governor)
        #expect(await eventually { bridge.childConcurrencySelection.runtime?.actualRunning == 0 })
        #expect(bridge.childConcurrencySelection.userSelected == 1)

        _ = await governor.requestLaunch(sessionID: "holder")
        #expect(await eventually { bridge.childConcurrencySelection.runtime?.actualRunning == 1 })
        let waiting = Task { await governor.requestLaunch(sessionID: "waiting") }
        #expect(await eventually { bridge.childConcurrencySelection.runtime?.queued == 1 })
        await governor.degradeActualConcurrency(to: 0, controlRevision: revision)
        #expect(await eventually {
            bridge.childConcurrencySelection.runtime?.degradedCeiling == 0
        })
        await governor.releaseLaunch(sessionID: "holder")
        #expect(await eventually {
            bridge.childConcurrencySelection.runtime?.actualRunning == 0
                && bridge.childConcurrencySelection.runtime?.queued == 1
        })
        await governor.engageKillSwitch(controlRevision: revision)
        if case .blockedByKillSwitch = await waiting.value { } else {
            Issue.record("queued request must be released by the shared governor")
        }
        #expect(await eventually {
            bridge.childConcurrencySelection.runtime?.newLaunchesStopped == true
                && bridge.childConcurrencySelection.runtime?.queued == 0
        })
        await governor.liftKillSwitch(controlRevision: revision)
        await governor.restoreActualConcurrency(controlRevision: revision)
        #expect(await eventually {
            bridge.childConcurrencySelection.runtime?.newLaunchesStopped == false
                && bridge.childConcurrencySelection.runtime?.degradedCeiling == nil
        })
        #expect(bridge.childConcurrencySelection.sideBySideProjection.count == 5)
    }

    @Test("unchanged settings callback keeps occupied shared slots while rebuilding production executors")
    func unchangedSettingsReattachPreservesGlobalAccounting854() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "child-accounting854", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled)
        let defaults = profile.makeUserDefaults()
        let keychain = profile.makeKeychainStore()
        let log = profile.makeLogManager()
        let readiness = ProviderReadinessStore(directory: profile.providerConfigurationDirectory)
        let settings = SettingsCenter(
            settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: EnvVarStore(directory: profile.minisCoreDirectory, keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            memoryFileStore: MemoryFileStore(directory: profile.rootDirectory.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            sessionBadgeStore: SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges")),
            logManager: log,
            mcpManager: MCPServerManager(fileURL: profile.mcpDirectory.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock, providerReadinessStore: readiness)
        settings.childConcurrencyUserSelected = 1
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: log,
            workflowStore: WorkflowStore(storeDirectory: profile.rootDirectory.appendingPathComponent("Workflows")),
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            canvasRuntimeState: .disabled, agentTaskStore: AgentTaskStore(),
            contextManifestStore: ContextManifestStore(), memoryStore: settings.memoryStore,
            memoryProposalConsumer: settings.memoryProposalConsumer, providerReadinessStore: readiness,
            taskCenterBindingPersistenceURL: profile.rootDirectory.appendingPathComponent("task-center-bindings.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
            })
        ProductionOrchestrationDefaults.attachCurrentProductionConfiguration(
            to: bridge, settings: settings, profile: profile,
            childConcurrencySelection: settings.childConcurrencySelection)
        ProductionOrchestrationDefaults.bindChildConcurrencySelection(
            to: bridge, settings: settings, profile: profile)
        defer { settings.onChildConcurrencySelectionChanged = nil }
        await bridge.lastChildGovernorSafetyTask?.value
        let old = try #require(bridge.orchestrationChildGovernor)
        let oldBuiltin = try #require(bridge.productionBuiltinToolExecutor)
        let oldEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let oldComposite = try #require(findComposite(in: oldEngine.composedExecutor))
        #expect(oldComposite.orchestration.orchestrator.childGovernor === old)
        let choice = settings.childConcurrencySelection
        let oldPolicyFacts = bridge.chat.composerPolicyFacts
        let settingsBytes = try Data(contentsOf: profile.settingsDirectory.appendingPathComponent(SettingsStore.fileName))
        guard case .admitted = await old.requestLaunch(sessionID: "854-existing-holder") else {
            Issue.record("owned holder must occupy the only shared slot")
            return
        }
        let oldControlRevision = try #require(bridge.childGovernorControlRevision)
        #expect(await old.degradeActualConcurrency(to: 0, controlRevision: oldControlRevision))

        // The ordinary production callback fires even when this acknowledgement
        // leaves the canonical selection unchanged. In-flight work owns `old`.
        settings.childConcurrencyRiskAcknowledged = false
        await bridge.lastChildGovernorSafetyTask?.value
        let current = try #require(bridge.orchestrationChildGovernor)
        let newBuiltin = try #require(bridge.productionBuiltinToolExecutor)
        let newEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let newComposite = try #require(findComposite(in: newEngine.composedExecutor))
        #expect(settings.childConcurrencySelection == choice)
        #expect(try Data(contentsOf: profile.settingsDirectory.appendingPathComponent(SettingsStore.fileName)) == settingsBytes)
        #expect(current === old)
        #expect(newBuiltin !== oldBuiltin) // executable permission/context wrappers are rebuilt
        #expect(newComposite.orchestration.orchestrator.childGovernor === current)
        #expect(newComposite.orchestration.orchestrator.childConcurrencySelection == choice)
        #expect(bridge.chat.composerPolicyFacts.revision != oldPolicyFacts.revision)
        #expect(await current.globalBudget == 1)
        let rebound = await current.checkpoint()
        #expect(rebound.globalActive == 1)
        #expect(rebound.perSessionActive == ["854-existing-holder": 1])
        #expect(rebound.degradedCeiling == 0)

        let request = ChildLaunchRequestID(rawValue: "854-next-session-request")
        let next = Task { await current.requestLaunch(sessionID: "854-next-session", requestID: request) }
        var queued = false
        for _ in 0..<100 {
            if await current.checkpoint().queuedSessions == ["854-next-session"] { queued = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(queued) // RED used to grant here on a newly empty governor
        let currentControlRevision = try #require(bridge.childGovernorControlRevision)
        #expect(await current.restoreActualConcurrency(controlRevision: currentControlRevision))
        let stillOccupied = await current.checkpoint()
        #expect(stillOccupied.globalActive == 1)
        #expect(stillOccupied.queuedSessions == ["854-next-session"])
        // Returning the original permit is the only event that may admit next.
        await old.releaseLaunch(sessionID: "854-existing-holder")
        await current.abandonWaiting(requestID: request) // bounded cleanup if a faulty implementation failed to dispatch
        let decision = await next.value
        guard case .admitted = decision else {
            Issue.record("returning the real old holder must resume the queued next session")
            return
        }
        let resumed = await current.checkpoint()
        #expect(resumed.globalActive == 1)
        #expect(resumed.perSessionActive == ["854-existing-holder": 0, "854-next-session": 1])
        #expect(resumed.queuedSessions.isEmpty)
        await current.releaseLaunch(sessionID: "854-next-session")
        #expect(await current.currentGlobalActive == 0)

        // An unrelated data root still fails before rebinding the governor or
        // executable owner. Retaining resource accounting grants no new scope.
        bridge.attachProductionServices(sessionDirectory: profile.rootDirectory.appendingPathComponent("foreign-sessions"),
            enableOrchestration: true, childConcurrencySelection: choice)
        #expect(bridge.orchestrationChildGovernor === current)
        let afterRejectedRoot = try #require(bridge.productionBuiltinToolExecutor)
        #expect(afterRejectedRoot === newBuiltin)
    }

    @Test("changed settings cannot create unaccounted permits beside an in-flight old governor")
    func changedSettingsCannotCreateUnaccountedPermits874() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "child-policy874", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled)
        let defaults = profile.makeUserDefaults()
        let keychain = profile.makeKeychainStore()
        let log = profile.makeLogManager()
        let readiness = ProviderReadinessStore(directory: profile.providerConfigurationDirectory)
        let settings = SettingsCenter(
            settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: EnvVarStore(directory: profile.minisCoreDirectory, keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            memoryFileStore: MemoryFileStore(directory: profile.rootDirectory.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            sessionBadgeStore: SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges")),
            logManager: log,
            mcpManager: MCPServerManager(fileURL: profile.mcpDirectory.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock, providerReadinessStore: readiness)
        settings.childConcurrencyUserSelected = 1
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: log,
            workflowStore: WorkflowStore(storeDirectory: profile.rootDirectory.appendingPathComponent("Workflows")),
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            canvasRuntimeState: .disabled, agentTaskStore: AgentTaskStore(),
            contextManifestStore: ContextManifestStore(), memoryStore: settings.memoryStore,
            memoryProposalConsumer: settings.memoryProposalConsumer, providerReadinessStore: readiness,
            taskCenterBindingPersistenceURL: profile.rootDirectory.appendingPathComponent("task-center-bindings.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
            })
        ProductionOrchestrationDefaults.attachCurrentProductionConfiguration(
            to: bridge, settings: settings, profile: profile,
            childConcurrencySelection: settings.childConcurrencySelection)
        ProductionOrchestrationDefaults.bindChildConcurrencySelection(
            to: bridge, settings: settings, profile: profile)
        defer { settings.onChildConcurrencySelectionChanged = nil }
        await bridge.lastChildGovernorSafetyTask?.value
        let old = try #require(bridge.orchestrationChildGovernor)
        let oldBuiltin = try #require(bridge.productionBuiltinToolExecutor)
        let oldEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let oldComposite = try #require(findComposite(in: oldEngine.composedExecutor))
        #expect(oldComposite.orchestration.orchestrator.childGovernor === old)
        guard case .admitted = await old.requestLaunch(sessionID: "874-old-holder") else {
            Issue.record("owned old policy holder did not obtain its only slot")
            return
        }
        let oldPolicyFacts = bridge.chat.composerPolicyFacts
        // Actual durable SettingsCenter producer changes 1 -> 2 inside the
        // recommendation; no risk bypass or manually rewritten projection.
        settings.childConcurrencyUserSelected = 2
        await bridge.lastChildGovernorSafetyTask?.value
        let current = try #require(bridge.orchestrationChildGovernor)
        let newBuiltin = try #require(bridge.productionBuiltinToolExecutor)
        #expect(newBuiltin !== oldBuiltin)
        #expect(bridge.chat.composerPolicyFacts.revision != oldPolicyFacts.revision)
        #expect(settings.childConcurrencyUserSelected == 2 && settings.childConcurrencyEffective == 2)
        #expect(SettingsStore(directory: profile.settingsDirectory).settings.agent.childConcurrencyUserSelected == 2)
        #expect(await current.globalBudget == 2)
        #expect(await old.checkpoint().perSessionActive["874-old-holder"] == 1)

        let firstID = ChildLaunchRequestID(rawValue: "874-new-first-request")
        let secondID = ChildLaunchRequestID(rawValue: "874-new-second-request")
        let first = Task { await current.requestLaunch(sessionID: "874-new-first", requestID: firstID) }
        for _ in 0..<100 {
            let cp = await current.checkpoint()
            if cp.perSessionActive["874-new-first"] == 1 || cp.queuedSessions.contains("874-new-first") { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let second = Task { await current.requestLaunch(sessionID: "874-new-second", requestID: secondID) }
        for _ in 0..<100 {
            let cp = await current.checkpoint()
            if cp.perSessionActive["874-new-second"] == 1 || cp.queuedSessions.contains("874-new-second") { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let next = await current.checkpoint()
        let previous = await old.checkpoint()
        let aggregate = current === old ? next.globalActive : next.globalActive + previous.globalActive
        #expect(aggregate == 2) // standing old permit + exactly one new permit
        #expect(next.queuedSessions == ["874-new-second"])
        #expect(previous.perSessionActive["874-old-holder"] == 1)
        // The old child is not killed or forgotten. Its original release must
        // still reach the resource account governing the new queue.
        await old.releaseLaunch(sessionID: "874-old-holder")
        await current.abandonWaiting(requestID: firstID)
        guard case .admitted = await first.value else {
            await current.abandonWaiting(requestID: secondID)
            _ = await second.value
            Issue.record("valid first new child was not admitted")
            return
        }
        await current.releaseLaunch(sessionID: "874-new-first")
        await current.abandonWaiting(requestID: secondID)
        guard case .admitted = await second.value else {
            Issue.record("returning the old and first new permits did not resume the second")
            return
        }
        await current.releaseLaunch(sessionID: "874-new-second")
        #expect(await old.currentGlobalActive == 0)
        #expect(await current.currentGlobalActive == 0)
    }

    #if DEBUG
    @Test("late Settings ABA keeps all physical holders and safety locks fence captured engines", arguments: [false, true])
    func lateSettingsRebindAndSafetyPreservePhysicalLedger921(useSafeMode: Bool) async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "child-rebind921", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled)
        let defaults = profile.makeUserDefaults()
        let keychain = profile.makeKeychainStore()
        let log = profile.makeLogManager()
        let readiness = ProviderReadinessStore(directory: profile.providerConfigurationDirectory)
        let settings = SettingsCenter(
            settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: EnvVarStore(directory: profile.minisCoreDirectory, keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            memoryFileStore: MemoryFileStore(directory: profile.rootDirectory.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            sessionBadgeStore: SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges")),
            logManager: log,
            mcpManager: MCPServerManager(fileURL: profile.mcpDirectory.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock, providerReadinessStore: readiness)
        settings.childConcurrencyUserSelected = 1
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: log,
            workflowStore: WorkflowStore(storeDirectory: profile.rootDirectory.appendingPathComponent("Workflows")),
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            canvasRuntimeState: .disabled, agentTaskStore: AgentTaskStore(),
            contextManifestStore: ContextManifestStore(), memoryStore: settings.memoryStore,
            memoryProposalConsumer: settings.memoryProposalConsumer, providerReadinessStore: readiness,
            taskCenterBindingPersistenceURL: profile.rootDirectory.appendingPathComponent("task-center-bindings.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
            })
        ProductionOrchestrationDefaults.bindChildConcurrencySelection(
            to: bridge, settings: settings, profile: profile)
        ProductionOrchestrationDefaults.bindSafetyRuntimeSnapshot(
            to: bridge, settings: settings, profile: profile)
        ProductionOrchestrationDefaults.bindPolicyRuntimeDefaults(
            to: bridge, settings: settings, profile: profile)
        let firstAttachmentTask = ProductionOrchestrationDefaults.attachCurrentProductionConfiguration(
            to: bridge, settings: settings, profile: profile,
            childConcurrencySelection: settings.childConcurrencySelection)
        let governor = try #require(bridge.orchestrationChildGovernor)
        let initialRevision = try #require(bridge.childGovernorControlRevision)
        let initialBuiltin = try #require(bridge.productionBuiltinToolExecutor)
        let initialEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let initialComposite = try #require(findComposite(in: initialEngine.composedExecutor))
        guard case .admitted = await governor.requestLaunch(sessionID: "921-old-holder") else {
            Issue.record("the real initial holder did not acquire its only permit"); return
        }
        let oldWaitingID = ChildLaunchRequestID(rawValue: "921-old-waiter")
        let oldWaiting = Task { await governor.requestLaunch(sessionID: "921-old-waiter", requestID: oldWaitingID) }
        for _ in 0..<100 {
            if await governor.checkpoint().queuedSessions == ["921-old-waiter"] { break }
            await Task.yield()
        }
        #expect(await governor.checkpoint().queuedSessions == ["921-old-waiter"])
        var settingsSourceReads = 0
        if !useSafeMode {
            _ = try #require(settings.bl6EffectiveSettingsSnapshot)
            bridge.bindProductionEffectiveSettingsSource {
                settingsSourceReads += 1
                return settings.bl6EffectiveSettingsSnapshot
            }
        } else {
            #expect(bridge.chat.effectiveSettingsSnapshotSource == nil)
        }
        bridge.chat.streamingProviderOverride = MockProvider.shared
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request, effort: .standard,
            bypassModeConfirmed: false)
        var sendCommands = 0
        bridge.chat.onSendCommand = { _, _ in sendCommands += 1; return false }
        let (preparationEntered, preparationEnteredContinuation) = AsyncStream<Void>.makeStream()
        let (preparationRelease, preparationReleaseContinuation) = AsyncStream<Void>.makeStream()
        defer { preparationReleaseContinuation.finish() }
        bridge.chat.turnPromptPreprocessPauseForTests = {
            preparationEnteredContinuation.yield(())
            var release = preparationRelease.makeAsyncIterator()
            _ = await release.next()
        }
        bridge.chat.draftText = "937-original-frozen"
        bridge.chat.submitComposer()
        let oldSubmission = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        let oldTurnTask = try #require(bridge.chat.turnTaskForTests(sessionID: bridge.chat.activeSessionID))
        var entered = preparationEntered.makeAsyncIterator()
        _ = await entered.next()
        #expect(bridge.chat.isStreaming)
        #expect(sendCommands == 1)
        let oldMessages = bridge.chat.messages
        let sourceSessionID = try #require(bridge.chat.activeSessionID)
        let oldExecutionIdentity = try #require(bridge.chat.activeExecutionIdentity(for: sourceSessionID))
        let sourceStore = try #require(bridge.chat.sessionStore)
        let sessionURL = sourceStore.sessionsDirectory.appendingPathComponent(sourceSessionID.uuidString + ".json")
        let oldSessionBytes = try Data(contentsOf: sessionURL)
        let readsBeforePending = settingsSourceReads
        var observedCompletedTransaction = false
        var preparedRevision: ChildConcurrencyGovernor.ControlRevision?
        var lateCommit: Task<Void, Never>?
        var pendingCredentialRequest: ChatCredentialBroker.Request?
        bridge.onProductionAttachmentPreparedForTesting = {
            bridge.onProductionAttachmentPreparedForTesting = nil
            observedCompletedTransaction = true
            preparedRevision = bridge.childGovernorControlRevision
            // The actual B actor transaction has completed; no B execution
            // wrapper may have published before the following real A callback.
            #expect(bridge.productionBuiltinToolExecutor === initialBuiltin)
            #expect(bridge.childConcurrencySelection.userSelected == 1)
            #expect(bridge.childConcurrencySelection.runtime == nil)
            #expect(bridge.chat.effectiveSettingsSnapshotSource != nil)
            #expect(bridge.chat.effectiveSettingsSnapshotSource?() == nil)
            // Editing protects credential-shaped text before submit. Freeze that
            // real local-custody baseline; pending submit must leave it unchanged
            // and must not progress to sending or provider credential resolution.
            let pendingDraft = "token=owned937sentinel"
            #expect(bridge.chat.credentialBroker.pending == nil)
            bridge.chat.draftText = pendingDraft
            let protectedDraft = bridge.chat.draftText
            let brokerRequest = bridge.chat.credentialBroker.pending
            let brokerOutcome = bridge.chat.credentialBroker.outcome
            let brokerConfirming = bridge.chat.credentialBroker.isConfirming
            let commandsBeforeBlockedSubmit = sendCommands
            #expect(protectedDraft != pendingDraft)
            #expect(!protectedDraft.contains("owned937sentinel"))
            #expect(brokerRequest != nil)
            #expect(brokerRequest?.sessionID == sourceSessionID)
            #expect(brokerRequest?.providerID == nil)
            #expect(!brokerConfirming)
            pendingCredentialRequest = brokerRequest
            bridge.chat.submitComposer()
            #expect(bridge.chat.lastSubmissionBlockedByInvalidSettings)
            #expect(bridge.chat.draftText == protectedDraft)
            #expect(bridge.chat.credentialBroker.pending == brokerRequest)
            #expect(bridge.chat.credentialBroker.outcome == brokerOutcome)
            #expect(bridge.chat.credentialBroker.isConfirming == brokerConfirming)
            #expect(sendCommands == commandsBeforeBlockedSubmit)
            #expect(bridge.chat.lastComposerSubmissionSnapshot?.taskID == oldSubmission.taskID)
            #expect(bridge.chat.messages == oldMessages)
            #expect((try? Data(contentsOf: sessionURL)) == oldSessionBytes)
            #expect(sendCommands == 1)
            #expect(settingsSourceReads == readsBeforePending)
            #expect(bridge.chat.activeExecutionIdentity(for: sourceSessionID) == oldExecutionIdentity)
            do {
                _ = try bridge.chat.activeProvider()
                Issue.record("pending rebind reached new provider construction")
            } catch let error as ChatStoreProviderError {
                #expect(error == .unavailable(providerID: "settings-transaction-unknown", protocolType: .other))
            } catch {
                Issue.record("pending provider construction returned an unexpected error category")
            }
            settings.childConcurrencyUserSelected = 1
            #expect(bridge.chat.effectiveSettingsSnapshotSource != nil)
            #expect(bridge.chat.effectiveSettingsSnapshotSource?() == nil)
            lateCommit = ProductionOrchestrationDefaults.attachCurrentProductionConfiguration(
                to: bridge, settings: settings, profile: profile,
                childConcurrencySelection: settings.childConcurrencySelection)
        }
        settings.childConcurrencyUserSelected = 2
        let pending = try #require(bridge.lastChildGovernorSafetyTask)
        await pending.value
        await lateCommit?.value
        #expect(observedCompletedTransaction)
        #expect(preparedRevision != nil && preparedRevision != initialRevision)
        let currentRevision = try #require(bridge.childGovernorControlRevision)
        #expect(currentRevision != initialRevision && currentRevision != preparedRevision)
        #expect(bridge.orchestrationChildGovernor === governor)
        #expect(settings.childConcurrencyUserSelected == 1)
        #expect(SettingsStore(directory: profile.settingsDirectory).settings.agent.childConcurrencyUserSelected == 1)
        #expect(bridge.childConcurrencySelection.userSelected == 1)
        #expect(await governor.globalBudget == 1)
        if useSafeMode {
            #expect(bridge.chat.effectiveSettingsSnapshotSource == nil)
        } else {
            #expect(bridge.chat.effectiveSettingsSnapshotSource?() == settings.bl6EffectiveSettingsSnapshot)
            #expect(settingsSourceReads == readsBeforePending + 1)
        }
        // TASK1003: read only this fixture's context file and public lifecycle
        // records. Never emit paths, identities, draft text or arbitrary errors.
        let latestEngine1003 = bridge.chat.agentEngine as? AgentLoopChatEngine
        let contextURL1003 = profile.sessionDirectory.appendingPathComponent("agent-turn-context-v1.json")
        func sampleLifecycle1003(
            _ phase: String, previousBytes: Data? = nil,
            latestIdentity: AgentExecutionIdentity? = nil
        ) -> Data? {
            var fields: [String: Any] = ["phase": phase, "useSafeMode": useSafeMode]
            let oldStore = initialEngine.contextWritebackGate.lifecycleStore
            let newStore = latestEngine1003?.contextWritebackGate.lifecycleStore
            fields["oldStorePresent"] = oldStore != nil
            fields["newStorePresent"] = newStore != nil
            fields["sameStore"] = oldStore != nil && oldStore === newStore
            fields["newEngineRecoveryFailure"] = latestEngine1003?.contextRecoveryFailure?.category ?? "noneOrUnavailable"
            let oldRecord = oldStore?.record(for: oldExecutionIdentity)
            let mirroredOldRecord = newStore?.record(for: oldExecutionIdentity)
            fields["oldStoreOldStatus"] = oldRecord?.status.rawValue ?? "absent"
            fields["newStoreOldStatus"] = mirroredOldRecord?.status.rawValue ?? "absent"
            if let record = oldRecord {
                fields["oldGeneration"] = record.generation
                fields["oldSequence"] = record.streamSequence
            }
            if let latestIdentity {
                let record = newStore?.record(for: latestIdentity)
                fields["newStoreLatestStatus"] = record?.status.rawValue ?? "absent"
                fields["newIdentityEqualsOld"] = latestIdentity == oldExecutionIdentity
            }
            let execution = bridge.chat.executionSnapshot(forSessionID: sourceSessionID)
            fields["executionState"] = execution?.state.rawValue ?? "unavailable"
            // This API exposes a rendered failure, not the original thrown
            // Error. Match only descriptions generated from fixed enum cases;
            // unmatched descriptions never leave this local comparison.
            let whitelist: [(String, AgentLoopChatEngine.ContextManifestConsumptionError)] = [
                ("executionIdentityRejected", .executionIdentityRejected),
                ("executionWritebackRejected", .executionWritebackRejected),
                ("persistenceFailed", .persistenceFailed),
                ("contextSettingsScopeMismatch", .contextSettingsScopeMismatch),
                ("invalidExecutionIdentity", .invalidExecutionIdentity),
                ("invalidContextSettings", .invalidContextSettings),
                ("rejected", .rejected)
            ]
            let matched = whitelist.first { execution?.failureReason == ChatStore.userErrorMessage($0.1) }
            fields["renderedErrorWhitelistMatch"] = matched?.0 ?? "UNKNOWN"
            fields["typedThrownErrorAvailable"] = false
            if let matched {
                let fixedError = matched.1 as NSError
                fields["fixedWhitelistNSErrorDomain"] = fixedError.domain
                fields["fixedWhitelistNSErrorCode"] = fixedError.code
            }
            var bytes: Data?
            // The runtime profile was built by this method. Refuse a replaced
            // nonregular or multiply linked file before the diagnostic read.
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: contextURL1003.path)
                if attributes[.type] as? FileAttributeType == .typeRegular,
                   (attributes[.referenceCount] as? NSNumber)?.intValue == 1 {
                    bytes = try Data(contentsOf: contextURL1003)
                    fields["contextRead"] = "regularOwnedFile"
                } else { fields["contextRead"] = "refusedNonregularOrLinked" }
            } catch {
                let error = error as NSError
                fields["contextRead"] = error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
                    ? "absent" : "UNKNOWN"
            }
            if let bytes {
                fields["contextSHA256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                fields["contextByteCount"] = bytes.count
            }
            if let previousBytes { fields["contextBytesChanged"] = bytes != previousBytes }
            if let json = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
               let safeLine = String(data: json, encoding: .utf8) {
                print("TASK1003 " + safeLine)
            }
            return bytes
        }
        let contextAfterRebind1003 = sampleLifecycle1003("latestAssemblyBeforeOldRelease")
        #expect(latestEngine1003?.contextWritebackGate === initialEngine.contextWritebackGate)
        #expect(latestEngine1003?.contextWritebackGate.lifecycleStore === initialEngine.contextWritebackGate.lifecycleStore)
        #expect(bridge.chat.lastComposerSubmissionSnapshot?.taskID == oldSubmission.taskID)
        #expect(pendingCredentialRequest != nil)
        #expect(bridge.chat.credentialBroker.pending == pendingCredentialRequest)
        // End only this owned local request through its production cancellation
        // API before the normal next-send positive control.
        bridge.chat.credentialBroker.cancel(sessionID: sourceSessionID)
        #expect(bridge.chat.credentialBroker.pending == nil)
        #expect(bridge.chat.credentialBroker.outcome == .cancelled)
        #expect(!bridge.chat.credentialBroker.isConfirming)
        bridge.chat.turnPromptPreprocessPauseForTests = nil
        preparationReleaseContinuation.yield(())
        preparationReleaseContinuation.finish()
        await oldTurnTask.value
        #expect(!bridge.chat.isStreaming)
        #expect(bridge.chat.messages.last(where: { $0.role == .assistant })?.content.contains("937-original-frozen") == true)
        let contextAfterOld1003 = sampleLifecycle1003("oldTurnFinished", previousBytes: contextAfterRebind1003)
        #expect(latestEngine1003?.contextWritebackGate.lifecycleStore?.record(for: oldExecutionIdentity)?.status == .completed)
        #expect(SettingsCenter.active === settings)
        let ownedContextResolution = SettingsCenter.contextTurnSettingsSnapshot(
            for: sourceStore, sessionID: sourceSessionID.uuidString,
            model: MockProvider.shared.model)
        let ownedContextAccepted: Bool
        switch ownedContextResolution {
        case .accepted: ownedContextAccepted = true
        case .ownerUnavailable:
            ownedContextAccepted = false; Issue.record("owned child next-turn context owner unavailable")
        case .scopeMismatch:
            ownedContextAccepted = false; Issue.record("owned child next-turn context scope mismatch")
        case .invalid:
            ownedContextAccepted = false; Issue.record("owned child next-turn context settings invalid")
        }
        try #require(ownedContextAccepted)
        bridge.chat.draftText = "937-new-after-latest"
        bridge.chat.submitComposer()
        #expect(!bridge.chat.lastSubmissionBlockedByInvalidSettings)
        let newSubmission = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        #expect(newSubmission.taskID != oldSubmission.taskID)
        #expect(sendCommands == 2)
        let newTurnTask = try #require(bridge.chat.turnTaskForTests(sessionID: sourceSessionID))
        let latestIdentity1003 = bridge.chat.activeExecutionIdentity(for: sourceSessionID)
        await newTurnTask.value
        let contextAfterLatest1013 = sampleLifecycle1003("latestTurnFinished", previousBytes: contextAfterOld1003,
            latestIdentity: latestIdentity1003)
        let latestIdentity1013 = try #require(latestIdentity1003)
        #expect(latestEngine1003?.contextWritebackGate.lifecycleStore?.record(for: latestIdentity1013)?.status == .completed)
        #expect(bridge.chat.executionSnapshot(forSessionID: sourceSessionID)?.state == .idle)
        #expect(contextAfterOld1003 != nil && contextAfterLatest1013 != nil)
        #expect(contextAfterLatest1013 != contextAfterOld1003)
        #expect(!bridge.chat.isStreaming)
        #expect(bridge.chat.messages.last(where: { $0.role == .assistant })?.content.contains("937-new-after-latest") == true)
        guard case .admitted = await oldWaiting.value else {
            Issue.record("the already committed B transaction lost its legitimate oldest waiter"); return
        }
        // B legitimately granted the oldest waiter before A arrived. A lowers
        // the hard limit without killing or falsely forgetting either holder.
        let held = await governor.checkpoint()
        #expect(held.globalActive == 2)
        #expect(held.perSessionActive == ["921-old-holder": 1, "921-old-waiter": 1])
        #expect(await governor.remainingBudget == 0)
        #expect(await eventually { bridge.childConcurrencySelection.runtime?.actualRunning == 2 })
        #expect(!(await governor.degradeActualConcurrency(to: 0, controlRevision: initialRevision)))
        let lateRequestID = ChildLaunchRequestID(rawValue: "921-after-A")
        let lateRequest = Task { await governor.requestLaunch(sessionID: "921-after-A", requestID: lateRequestID) }
        for _ in 0..<100 {
            if await governor.checkpoint().queuedSessions == ["921-after-A"] { break }
            await Task.yield()
        }
        #expect(await governor.checkpoint().queuedSessions == ["921-after-A"])
        await governor.releaseLaunch(sessionID: "921-old-holder")
        #expect(await governor.currentGlobalActive == 1)
        #expect(await governor.checkpoint().queuedSessions == ["921-after-A"])
        await governor.releaseLaunch(sessionID: "921-old-waiter")
        guard case .admitted = await lateRequest.value else { Issue.record("real second old release did not resume next"); return }
        await governor.releaseLaunch(sessionID: "921-after-A")
        #expect(await governor.currentGlobalActive == 0)
        #expect(await governor.checkpoint().perSessionActive == [
            "921-old-holder": 0, "921-old-waiter": 0, "921-after-A": 0])

        // Cancellation after the actor CAS cannot reopen the old wrappers or
        // pretend to roll the resource configuration back. A later real A
        // settings callback retries on that same actor and releases the gate.
        let beforeCancelledBuiltin = try #require(bridge.productionBuiltinToolExecutor)
        let beforeCancelledRevision = try #require(bridge.childGovernorControlRevision)
        let beforeCancelledMessages = bridge.chat.messages
        let beforeCancelledBytes = try Data(contentsOf: sessionURL)
        let beforeCancelledCommands = sendCommands
        await firstAttachmentTask.value
        var lateSourceReads = 0
        let readsBeforeLateSourceBinding = settingsSourceReads
        bridge.onProductionAttachmentPreparedForTesting = {
            bridge.onProductionAttachmentPreparedForTesting = nil
            // The same production source-binding call used after startup's
            // first-attach await must not overwrite a callback's pending gate.
            bridge.bindProductionEffectiveSettingsSource {
                lateSourceReads += 1
                return settings.bl6EffectiveSettingsSnapshot
            }
            #expect(bridge.chat.effectiveSettingsSnapshotSource != nil)
            #expect(bridge.chat.effectiveSettingsSnapshotSource?() == nil)
            #expect(lateSourceReads == 0)
            bridge.lastChildGovernorSafetyTask?.cancel()
        }
        settings.childConcurrencyUserSelected = 2
        let cancelledCommit = try #require(bridge.lastChildGovernorSafetyTask)
        await cancelledCommit.value
        #expect(cancelledCommit.isCancelled)
        #expect(bridge.childGovernorControlRevision != beforeCancelledRevision)
        #expect(await governor.globalBudget == 2)
        #expect(bridge.productionBuiltinToolExecutor === beforeCancelledBuiltin)
        #expect(bridge.childConcurrencySelection.userSelected == 1)
        #expect(bridge.chat.effectiveSettingsSnapshotSource != nil)
        #expect(bridge.childConcurrencySelection.runtime == nil)
        #expect(bridge.chat.effectiveSettingsSnapshotSource?() == nil)
        #expect(bridge.chat.credentialBroker.pending == nil)
        bridge.chat.draftText = "token=owned937cancelled"
        let cancelledProtectedDraft = bridge.chat.draftText
        let cancelledCredentialRequest = try #require(bridge.chat.credentialBroker.pending)
        let cancelledCredentialOutcome = bridge.chat.credentialBroker.outcome
        #expect(!cancelledProtectedDraft.contains("owned937cancelled"))
        #expect(cancelledCredentialRequest.sessionID == sourceSessionID)
        #expect(cancelledCredentialRequest.providerID == nil)
        #expect(!bridge.chat.credentialBroker.isConfirming)
        bridge.chat.submitComposer()
        #expect(bridge.chat.lastSubmissionBlockedByInvalidSettings)
        #expect(bridge.chat.draftText == cancelledProtectedDraft)
        #expect(bridge.chat.credentialBroker.pending == cancelledCredentialRequest)
        #expect(bridge.chat.credentialBroker.outcome == cancelledCredentialOutcome)
        #expect(!bridge.chat.credentialBroker.isConfirming)
        #expect(bridge.chat.lastComposerSubmissionSnapshot?.taskID == newSubmission.taskID)
        #expect(bridge.chat.messages == beforeCancelledMessages)
        #expect(try Data(contentsOf: sessionURL) == beforeCancelledBytes)
        #expect(sendCommands == beforeCancelledCommands)
        settings.childConcurrencyUserSelected = 1
        let retriedCommit = try #require(bridge.lastChildGovernorSafetyTask)
        await retriedCommit.value
        #expect(!retriedCommit.isCancelled)
        #expect(bridge.orchestrationChildGovernor === governor)
        #expect(await governor.globalBudget == 1)
        #expect(bridge.chat.effectiveSettingsSnapshotSource?() == settings.bl6EffectiveSettingsSnapshot)
        #expect(lateSourceReads == 1)
        #expect(settingsSourceReads == readsBeforeLateSourceBinding)
        #expect(bridge.chat.credentialBroker.pending == cancelledCredentialRequest)
        bridge.chat.credentialBroker.cancel(sessionID: sourceSessionID)
        #expect(bridge.chat.credentialBroker.pending == nil)
        #expect(bridge.chat.credentialBroker.outcome == .cancelled)
        #expect(!bridge.chat.credentialBroker.isConfirming)
        bridge.chat.draftText = "937-after-cancel-retry"
        bridge.chat.submitComposer()
        #expect(!bridge.chat.lastSubmissionBlockedByInvalidSettings)
        let retriedTurn = try #require(bridge.chat.turnTaskForTests(sessionID: sourceSessionID))
        await retriedTurn.value
        #expect(bridge.chat.messages.last(where: { $0.role == .assistant })?.content.contains("937-after-cancel-retry") == true)
        #expect(sendCommands == beforeCancelledCommands + 1)

        let lowered = ProductionPolicyDefaults(budget: 0, deadlineHorizon: 300,
            autonomyLevel: .l0, networkDomains: [])
        #expect(settings.updatePolicyRuntimeDefaults(lowered))
        await bridge.lastChildGovernorSafetyTask?.value
        #expect(bridge.orchestrationChildGovernor === governor)
        #expect(bridge.childGovernorControlRevision != currentRevision)
        #expect(bridge.chat.composerPolicyFacts.autonomyCeiling == .l0)
        let policyRevision = try #require(bridge.childGovernorControlRevision)
        let currentEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let currentComposite = try #require(findComposite(in: currentEngine.composedExecutor))
        #expect(currentComposite.orchestration.orchestrator.childGovernor === governor)
        guard case .admitted = await governor.requestLaunch(sessionID: "921-safety-holder") else {
            Issue.record("current policy did not grant the valid safety fixture holder"); return
        }
        if useSafeMode { settings.enableSafeMode() } else { settings.engageKillSwitch() }
        await bridge.lastChildGovernorSafetyTask?.value
        #expect(bridge.orchestrationChildGovernor == nil)
        #expect(bridge.childConcurrencySelection.runtime == nil)
        #expect(await governor.currentGlobalActive == 1)
        #expect(!(await governor.liftKillSwitch(controlRevision: policyRevision)))
        let oldCapturedGovernor = try #require(initialComposite.orchestration.orchestrator.childGovernor)
        guard case .blockedByKillSwitch = await oldCapturedGovernor.requestLaunch(sessionID: "921-disabled-old-engine") else {
            Issue.record("a captured engine obtained a slot while effective orchestration was disabled"); return
        }
        if useSafeMode { settings.disableSafeMode() } else { settings.disengageKillSwitch() }
        await bridge.lastChildGovernorSafetyTask?.value
        #expect(bridge.orchestrationChildGovernor === governor)
        #expect(await governor.currentGlobalActive == 1)
        #expect(await governor.remainingBudget == 0)
        await governor.releaseLaunch(sessionID: "921-safety-holder")
        #expect(await governor.currentGlobalActive == 0)

        // Idempotence is limited to the current session's accepted value.
        // Different input still creates a new local request, and a different
        // real session cannot inherit trust for the same protected string.
        bridge.chat.draftText = "token=owned987different"
        let differentRequest = try #require(bridge.chat.credentialBroker.pending)
        #expect(differentRequest.id != pendingCredentialRequest?.id)
        #expect(differentRequest.sessionID == sourceSessionID)
        let acceptedCurrentDraft = bridge.chat.draftText
        #expect(!acceptedCurrentDraft.contains("owned987different"))
        bridge.chat.draftText = acceptedCurrentDraft
        #expect(bridge.chat.draftText == acceptedCurrentDraft)
        #expect(bridge.chat.credentialBroker.pending == differentRequest)
        bridge.chat.credentialBroker.cancel(sessionID: sourceSessionID)
        #expect(bridge.chat.credentialBroker.pending == nil)
        bridge.chat.newSession()
        let differentSessionID = try #require(bridge.chat.activeSessionID)
        #expect(differentSessionID != sourceSessionID)
        bridge.chat.draftText = acceptedCurrentDraft
        let differentSessionRequest = try #require(bridge.chat.credentialBroker.pending)
        #expect(differentSessionRequest.sessionID == differentSessionID)
        #expect(differentSessionRequest.id != differentRequest.id)
        bridge.chat.credentialBroker.cancel(sessionID: differentSessionID)
        #expect(bridge.chat.credentialBroker.pending == nil)
        #expect(bridge.chat.credentialBroker.outcome == .cancelled)
        // Existing accepted prose can later become an explicitly known opaque
        // value. Equal-value reuse must still apply the existing redactor.
        let ownedOpaque = "owned987opaquevalue"
        bridge.chat.draftText = ownedOpaque
        let opaqueRequest = try #require(bridge.chat.credentialBroker.captureSecureField(
            ownedOpaque, sessionID: differentSessionID))
        bridge.chat.draftText = ownedOpaque
        #expect(!bridge.chat.draftText.contains(ownedOpaque))
        #expect(bridge.chat.credentialBroker.pending == opaqueRequest)
        bridge.chat.credentialBroker.cancel(sessionID: differentSessionID)
        #expect(bridge.chat.credentialBroker.pending == nil)

        // A different owned root cannot borrow this Bridge's retained durable
        // authority. Rejection keeps the current wrappers and both histories.
        let beforeForeignEngine1013 = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let beforeForeignBuiltin1013 = try #require(bridge.productionBuiltinToolExecutor)
        let beforeForeignRecord1013 = beforeForeignEngine1013.contextWritebackGate.lifecycleStore?.record(for: latestIdentity1013)
        let beforeForeignBytes1013 = try Data(contentsOf: contextURL1003)
        let foreignRoot1013 = profile.rootDirectory.appendingPathComponent("foreign-context1013", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: foreignRoot1013.path))
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: profile.rootDirectory,
            sessionDirectory: foreignRoot1013, enableOrchestration: true).value
        let afterForeignEngine1013 = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(afterForeignEngine1013.contextWritebackGate === beforeForeignEngine1013.contextWritebackGate)
        #expect(bridge.productionBuiltinToolExecutor === beforeForeignBuiltin1013)
        #expect(afterForeignEngine1013.contextWritebackGate.lifecycleStore?.record(for: latestIdentity1013) == beforeForeignRecord1013)
        #expect(try Data(contentsOf: contextURL1003) == beforeForeignBytes1013)
        #expect(!FileManager.default.fileExists(atPath: foreignRoot1013.path))
    }
    #endif

    @Test("rebind retains physical holders and rejects every stale configuration control")
    func rebindFencesStaleGovernor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("child-report-rebind-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldSelection = try ChildConcurrencySelection(userSelected: 1,
            recommended: 1, effective: 1)
        let newSelection = try ChildConcurrencySelection(userSelected: 2,
            recommended: 2, effective: 2)
        let bridge = BridgeStore()
        bridge.attachProductionServices(fileAccessAllowedRoot: root,
            sessionDirectory: root, enableOrchestration: true,
            childConcurrencySelection: oldSelection)
        let old = try #require(bridge.orchestrationChildGovernor)
        let oldRevision = try #require(bridge.childGovernorControlRevision)
        let oldEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let oldComposite = try #require(findComposite(in: oldEngine.composedExecutor))
        _ = await old.requestLaunch(sessionID: "old")
        #expect(await eventually { bridge.childConcurrencySelection.runtime?.actualRunning == 1 })

        await bridge.attachProductionServices(fileAccessAllowedRoot: root,
            sessionDirectory: root, enableOrchestration: true,
            childConcurrencySelection: newSelection).value
        let current = try #require(bridge.orchestrationChildGovernor)
        let currentRevision = try #require(bridge.childGovernorControlRevision)
        #expect(current === old)
        #expect(currentRevision != oldRevision)
        #expect(oldComposite.orchestration.orchestrator.childGovernor === current)
        #expect(await current.globalBudget == 2)
        #expect(await eventually {
            bridge.childConcurrencySelection.userSelected == 2
                && bridge.childConcurrencySelection.effective == 2
                && bridge.childConcurrencySelection.runtime?.actualRunning == 1
        })
        let beforeStaleControls = await current.checkpoint()
        #expect(!(await old.degradeActualConcurrency(to: 0, controlRevision: oldRevision)))
        #expect(!(await old.restoreActualConcurrency(controlRevision: oldRevision)))
        #expect(!(await old.engageKillSwitch(controlRevision: oldRevision)))
        #expect(!(await old.liftKillSwitch(controlRevision: oldRevision)))
        await old.degradeActualConcurrency(to: 0)
        await old.restoreActualConcurrency()
        await old.engageKillSwitch()
        await old.liftKillSwitch()
        #expect(await current.checkpoint() == beforeStaleControls)
        // Old permits are real physical ownership, not stale control authority.
        await old.releaseLaunch(sessionID: "old")
        #expect(await eventually { bridge.childConcurrencySelection.runtime?.actualRunning == 0 })
        #expect(bridge.childConcurrencySelection.runtime?.degradedCeiling == nil)

        #expect(await current.degradeActualConcurrency(to: 0, controlRevision: currentRevision))
        #expect(await current.checkpoint().degradedCeiling == 0)
        #expect(await current.restoreActualConcurrency(controlRevision: currentRevision))
        #expect(await current.checkpoint().degradedCeiling == nil)
        #expect(await current.engageKillSwitch(controlRevision: currentRevision))
        guard case .blockedByKillSwitch = await current.requestLaunch(sessionID: "current-stop") else {
            Issue.record("current controller did not actually stop admission")
            return
        }
        #expect(await current.liftKillSwitch(controlRevision: currentRevision))
        let live = await current.requestLaunch(sessionID: "retained-live")
        guard case .admitted = live else { Issue.record("current lift did not admit"); return }
        await bridge.attachProductionServices(fileAccessAllowedRoot: root,
            sessionDirectory: root, enableOrchestration: false,
            childConcurrencySelection: newSelection).value
        #expect(bridge.orchestrationChildGovernor == nil)
        #expect(bridge.childConcurrencySelection.runtime == nil)
        #expect(bridge.childConcurrencySelection.sideBySideProjection[3].value == nil)
        #expect(bridge.childConcurrencySelection.sideBySideProjection[4].value == nil)
        #expect(await old.currentGlobalActive == 1)
        let capturedGovernor = try #require(oldComposite.orchestration.orchestrator.childGovernor)
        guard case .blockedByKillSwitch = await capturedGovernor.requestLaunch(sessionID: "old-engine-disabled") else {
            Issue.record("disabled old engine obtained an unaccounted new permit")
            await old.releaseLaunch(sessionID: "retained-live")
            return
        }
        await bridge.attachProductionServices(fileAccessAllowedRoot: root,
            sessionDirectory: root, enableOrchestration: true,
            childConcurrencySelection: oldSelection).value
        let returned = try #require(bridge.orchestrationChildGovernor)
        let returnedRevision = try #require(bridge.childGovernorControlRevision)
        #expect(returned === old && returnedRevision != oldRevision)
        #expect(await returned.globalBudget == 1)
        #expect(await returned.currentGlobalActive == 1)
        #expect(!(await old.engageKillSwitch(controlRevision: oldRevision))) // A-B-A remains fenced
        let ownerBeforeRejectedRoot = try #require(bridge.productionBuiltinToolExecutor)
        await bridge.attachProductionServices(sessionDirectory: root.appendingPathComponent("foreign"),
            enableOrchestration: true, childConcurrencySelection: newSelection).value
        #expect(bridge.productionBuiltinToolExecutor === ownerBeforeRejectedRoot)
        #expect(bridge.childGovernorControlRevision == returnedRevision)
        #expect(await returned.globalBudget == 1)
        await old.releaseLaunch(sessionID: "retained-live")
        #expect(await old.currentGlobalActive == 0)
    }

}

private func findComposite(in executor: any ToolExecutor) -> OrchestrationCompositeToolExecutor? {
    if let composite = executor as? OrchestrationCompositeToolExecutor {
        return composite
    }
    if let concurrent = executor as? ConcurrentToolLimitingExecutor {
        return findComposite(in: concurrent.baseBox.value)
    }
    if let recording = executor as? RecordingToolExecutor {
        return findComposite(in: recording.base)
    }
    if let policy = executor as? PolicyEnforcedToolExecutor {
        return findComposite(in: policy.base)
    }
    for child in Mirror(reflecting: executor).children where child.label == "base" {
        if let base = child.value as? any ToolExecutor {
            return findComposite(in: base)
        }
    }
    return nil
}
