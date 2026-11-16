import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Observes the real credential-binding metadata read, never a credential
/// value. A pulse on the UI actor releases this physical read boundary.
private final class MetadataReadGate2801: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let released = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var armed = false
    private var enteredOnce = false
    private var main = false
    private var expired = false
    private var replaced = false
    func recordReplacement(_ succeeded: Bool) { lock.withLock { replaced = succeeded } }
    var didReplace: Bool { lock.withLock { replaced } }
    func arm() { lock.withLock { armed = true } }
    var didEnter: Bool { lock.withLock { enteredOnce } }
    var onMain: Bool { lock.withLock { main } }
    var timedOut: Bool { lock.withLock { expired } }
    func read() {
        let hold = lock.withLock { () -> Bool in
            guard armed, !enteredOnce else { return false }
            enteredOnce = true
            main = Thread.isMainThread
            return true
        }
        guard hold else { return }
        entered.signal()
        let timeout = released.wait(timeout: .now() + .seconds(1)) == .timedOut
        lock.withLock { expired = timeout }
    }
}

@Suite("PERF06 actual provider credential metadata preparation", .serialized)
@MainActor
struct ProviderMetadataPreparation2801Tests {
    @Test
    func switchingSessionsDuringActualMetadataReadShowsUnsentDraftInOriginalSession() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "ComposerSwitch0825",
            processEnvironment: [:], processArguments: ["MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled)
        let defaults = profile.makeUserDefaults()
        let keychain = profile.makeKeychainStore()
        let gate = MetadataReadGate2801()
        let env = EnvVarStore(directory: profile.providerConfigurationDirectory,
            keychain: keychain, privacyStore: EnvVarPrivacyStore(defaults: defaults),
            credentialBindingMetadataReadObserver: { gate.read() })
        let sessions = SessionStore(directory: profile.sessionDirectory)
        let aID = UUID()
        let bID = UUID()
        for (id, title) in [(aID, "Original A0825"), (bID, "Other B0825")] {
            _ = try sessions.createSession(id: id.uuidString, title: title,
                projectID: "project0825", projectName: "Owned0825",
                workingDirectory: profile.rootDirectory.path)
        }
        let badges = SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges"))
        let readiness = ProviderReadinessStore(directory: profile.providerConfigurationDirectory)
        let shortcuts = ShortcutStore(defaults: defaults)
        let settings = SettingsCenter(settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: env, memoryStore: MemoryStore(directory: profile.memoryDirectory),
            memoryFileStore: MemoryFileStore(directory: profile.rootDirectory.appendingPathComponent("memory-files")),
            sessionStore: sessions, sessionBadgeStore: badges, logManager: profile.makeLogManager(),
            mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
            skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain), shortcutStore: shortcuts,
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock, providerReadinessStore: readiness)
        let name = "SYNTHETIC_PROVIDER_0825"
        #expect(settings.saveProvider(name: name, apiKey: "owned synthetic fixture credential",
            baseURL: "https://example.invalid", modelNames: ["owned-model0825"],
            protocolType: .openaiCompatible))
        let record = try #require(settings.providerRecords.first { $0.name == name })
        let checkedAt = Date()
        #expect(readiness.upsert([ProviderReadinessPersistenceRecord(providerID: name,
            modelID: "owned-model0825", status: .passed, readinessState: .mock,
            checkedAt: checkedAt, evidenceID: "readiness0825", isApplied: true,
            discoveryReceiptID: "discovery0825", discoveredAt: checkedAt,
            applyReceiptID: "provider-readiness-apply:0825", appliedAt: checkedAt)]))
        let bridge = BridgeStore(shortcutStore: shortcuts, preferencesDefaults: defaults,
            logManager: settings.logManager,
            workflowStore: WorkflowStore(storeDirectory: profile.rootDirectory.appendingPathComponent("workflows")),
            sessionBadgeStore: badges, sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            canvasRuntimeState: .disabled,
            agentTaskStore: try AgentTaskStore(persistenceURL: profile.rootDirectory.appendingPathComponent("tasks.json")),
            contextManifestStore: try ContextManifestStore(persistenceURL: profile.rootDirectory.appendingPathComponent("manifests.json")),
            memoryStore: settings.memoryStore, memoryProposalConsumer: settings.memoryProposalConsumer,
            providerReadinessStore: readiness,
            taskCenterBindingPersistenceURL: profile.rootDirectory.appendingPathComponent("taskcenter.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in SpeechToolDirectObservations() })
        let chat = bridge.chat
        #expect(chat.attachPersistence(sessions, badgeStore: badges))
        #expect(chat.applySwitchSession(id: aID))
        bridge.bindProductionEffectiveSettingsSource { settings.bl6EffectiveSettingsSnapshot }
        chat.restoreComposerPolicy(settings.settings.agent.composerPolicy)
        chat.providerRecordsSource = { settings.providerRecords }
        // Match the AppMain metadata projection: await the actual owned Store
        // read, returning only an opaque revision and never a secret.
        chat.providerCredentialMetadataSource = { recordID, name in
            guard let current = settings.providerRecords.first(where: {
                      $0.id == recordID && $0.name == name
                  }),
                  let binding = await settings.providerCredentialBindingAsync(recordID: current.id),
                  binding.credentialName == name else { return nil }
            return binding.revision
        }
        chat.schedulerCredentialVersionSource = { providerID in
            guard let current = settings.providerRecords.first(where: { $0.name == providerID }) else { return nil }
            return settings.providerCredentialBinding(recordID: current.id)?.revision
        }
        await ProductionOrchestrationDefaults.attachCurrentProductionConfiguration(
            to: bridge, settings: settings, profile: profile,
            childConcurrencySelection: settings.childConcurrencySelection).value
        defer { gate.released.signal(); chat.stopAllStreamingForSafety() }
        try #require(chat.canSelectChatModel(providerID: record.name, modelID: "owned-model0825"))
        chat.setCustomProvider(record)
        #expect(chat.streamingProviderOverride == nil)
        chat.draftText = "ORIGINAL_A_UNSENT_0825"
        let aAttachmentURL = profile.rootDirectory.appendingPathComponent("owned-a-0825.txt")
        try Data("OWNED_A_ATTACHMENT_0825".utf8).write(to: aAttachmentURL)
        let aAttachmentID = try #require(chat.addAttachments(urls: [aAttachmentURL]).first?.id)
        let attachmentDeadline = ContinuousClock.now + .seconds(6)
        while chat.pendingAttachments.first?.status != .ready && ContinuousClock.now < attachmentDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(chat.pendingAttachments.first?.id == aAttachmentID)
        #expect(chat.pendingAttachments.first?.status == .ready)
        #expect(chat.selectedCustomProvider?.id == record.id)
        #expect(chat.selectedModelID == "owned-model0825")
        gate.arm()
        chat.submitComposer()
        let enterDeadline = ContinuousClock.now + .seconds(6)
        while !gate.didEnter && ContinuousClock.now < enterDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(gate.didEnter && !gate.onMain && !gate.timedOut)
        #expect(chat.isComposerProviderPreparationPending)
        #expect(chat.applySwitchSession(id: bID))
        #expect(chat.pastedTextActionFeedback?.contains("上一会话的模型请求未发送") == true)
        #expect(chat.pendingAttachments.isEmpty)
        gate.released.signal()
        let settleDeadline = ContinuousClock.now + .seconds(6)
        while chat.isComposerCredentialPreflightPending && ContinuousClock.now < settleDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!chat.isComposerCredentialPreflightPending)
        #expect(chat.messages.isEmpty)
        #expect(bridge.providerRuntimeObservations.isEmpty)
        #expect(try #require(sessions.loadSession(id: aID.uuidString)).messages.isEmpty)
        #expect(try #require(sessions.loadSession(id: bID.uuidString)).messages.isEmpty)

        chat.setProvider(nil)
        chat.draftText = "INDEPENDENT_B_0825"
        chat.submitComposer()
        let bDeadline = ContinuousClock.now + .seconds(6)
        while !chat.messages.contains(where: { $0.role == .assistant && $0.content.contains("INDEPENDENT_B_0825") })
            && ContinuousClock.now < bDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(chat.messages.contains { $0.role == .user && $0.content == "INDEPENDENT_B_0825" })
        #expect(bridge.providerRuntimeObservations.count == 1)
        #expect(bridge.providerRuntimeObservations.first?.servedProviderID == "Mock")
        #expect(try #require(sessions.loadSession(id: aID.uuidString)).messages.isEmpty)

        #expect(chat.applySwitchSession(id: aID))
        #expect(chat.draftText == "ORIGINAL_A_UNSENT_0825")
        #expect(chat.pendingAttachments.first?.id == aAttachmentID)
        #expect(chat.pendingAttachments.first?.fileName == "owned-a-0825.txt")
        #expect(chat.selectedCustomProvider?.id == record.id)
        #expect(chat.selectedModelID == "owned-model0825",
                "B switching to Mock must not change A's selected model")
        #expect(chat.pastedTextActionFeedback?.contains("模型请求未发送") == true)
        #expect(chat.messages.isEmpty)
    }

    @Test(arguments: ["cancel", "change-provider", "edit-draft", "replace-same-name"])
    func initialBindingReadAllowsPulseCancellationAndNextProductionTurn(action: String) async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "Metadata2801",
            processEnvironment: [:], processArguments: ["MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled)
        let defaults = profile.makeUserDefaults()
        let keychain = profile.makeKeychainStore()
        let gate = MetadataReadGate2801()
        let env = EnvVarStore(directory: profile.providerConfigurationDirectory,
            keychain: keychain, privacyStore: EnvVarPrivacyStore(defaults: defaults),
            credentialBindingMetadataReadObserver: { gate.read() })
        let sessions = SessionStore(directory: profile.sessionDirectory)
        let id = UUID()
        _ = try sessions.createSession(id: id.uuidString, title: "Metadata2801",
            projectID: "project2801", projectName: "Owned2801",
            workingDirectory: profile.rootDirectory.path)
        let badges = SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges"))
        let readiness = ProviderReadinessStore(directory: profile.providerConfigurationDirectory)
        let shortcuts = ShortcutStore(defaults: defaults)
        let settings = SettingsCenter(settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: env, memoryStore: MemoryStore(directory: profile.memoryDirectory),
            memoryFileStore: MemoryFileStore(directory: profile.rootDirectory.appendingPathComponent("memory-files")),
            sessionStore: sessions, sessionBadgeStore: badges, logManager: profile.makeLogManager(),
            mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
            skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain), shortcutStore: shortcuts,
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock, providerReadinessStore: readiness)
        // The profile's keychain implementation is synthetic. No native
        // Keychain, process credential or network transport is consulted.
        let name = "SYNTHETIC_PROVIDER_2801"
        #expect(settings.saveProvider(name: name, apiKey: "owned synthetic fixture credential",
            baseURL: "https://example.invalid", modelNames: ["owned-model2801"],
            protocolType: .openaiCompatible))
        let record = try #require(settings.providerRecords.first { $0.name == name })
        let binding = try #require(settings.providerCredentialBinding(recordID: record.id))
        #expect(!binding.revision.isEmpty)
        // saveProvider has already discovered/applied this model at the current
        // time. A 1970 health receipt is correctly ignored as older than that
        // canonical record and would send this test through Mock instead.
        let readinessCheckedAt = Date()
        #expect(readiness.upsert([ProviderReadinessPersistenceRecord(providerID: name,
            modelID: "owned-model2801", status: .passed, readinessState: .mock,
            checkedAt: readinessCheckedAt, evidenceID: "readiness2801",
            isApplied: true, discoveryReceiptID: "discovery2801",
            discoveredAt: readinessCheckedAt,
            applyReceiptID: "provider-readiness-apply:2801",
            appliedAt: readinessCheckedAt)]))
        let bridge = BridgeStore(shortcutStore: shortcuts, preferencesDefaults: defaults,
            logManager: settings.logManager,
            workflowStore: WorkflowStore(storeDirectory: profile.rootDirectory.appendingPathComponent("workflows")),
            sessionBadgeStore: badges, sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            canvasRuntimeState: .disabled,
            agentTaskStore: try AgentTaskStore(persistenceURL: profile.rootDirectory.appendingPathComponent("tasks.json")),
            contextManifestStore: try ContextManifestStore(persistenceURL: profile.rootDirectory.appendingPathComponent("manifests.json")),
            memoryStore: settings.memoryStore, memoryProposalConsumer: settings.memoryProposalConsumer,
            providerReadinessStore: readiness,
            taskCenterBindingPersistenceURL: profile.rootDirectory.appendingPathComponent("taskcenter.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in SpeechToolDirectObservations() })
        let chat = bridge.chat
        #expect(chat.attachPersistence(sessions, badgeStore: badges))
        #expect(chat.applySwitchSession(id: id))
        bridge.bindProductionEffectiveSettingsSource { settings.bl6EffectiveSettingsSnapshot }
        chat.restoreComposerPolicy(settings.settings.agent.composerPolicy)
        chat.providerRecordsSource = { settings.providerRecords }
        // The same actual record-bound async metadata source as AppMain.
        chat.providerCredentialMetadataSource = { recordID, name in
            guard let current = settings.providerRecords.first(where: {
                      $0.id == recordID && $0.name == name
                  }),
                  let binding = await settings.providerCredentialBindingAsync(recordID: current.id),
                  binding.credentialName == name else { return nil }
            return binding.revision
        }
        // This is the production AppMain metadata-only revision projection.
        chat.schedulerCredentialVersionSource = { providerID in
            guard let current = settings.providerRecords.first(where: { $0.name == providerID }) else { return nil }
            return settings.providerCredentialBinding(recordID: current.id)?.revision
        }
        await ProductionOrchestrationDefaults.attachCurrentProductionConfiguration(
            to: bridge, settings: settings, profile: profile,
            childConcurrencySelection: settings.childConcurrencySelection).value
        defer { gate.released.signal(); chat.stopAllStreamingForSafety() }
        let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        #expect(chat.providerRuntimeRouteFactory != nil)
        #expect(chat.turnRuntimeSnapshotFactory != nil)
        try #require(chat.canSelectChatModel(providerID: record.name, modelID: "owned-model2801"),
            "the actual production picker must accept the synthetic readiness before arming metadata")
        chat.setCustomProvider(record)
        #expect(chat.selectedCustomProvider?.id == record.id)
        #expect(chat.selectedModelID == "owned-model2801")
        chat.draftText = "cancel before Provider construction2801"
        // A second actual store publishes into the same owned metadata and
        // synthetic credential domain while the first store's read is held.
        // It has its own lock, so replacement cannot block the UI pulse on the
        // first store's lock. The original identity/token guards must reject it.
        let replacementStore = action == "replace-same-name"
            ? EnvVarStore(directory: profile.providerConfigurationDirectory,
                keychain: keychain, privacyStore: EnvVarPrivacyStore(defaults: defaults)) : nil
        gate.arm()
        let pulseTask = DispatchQueue.global(qos: .userInitiated)
        pulseTask.async {
            guard gate.entered.wait(timeout: .now() + .seconds(5)) == .success else {
                gate.released.signal()
                return
            }
            Task { @MainActor in
                switch action {
                case "change-provider": chat.setProvider(nil)
                case "edit-draft": chat.draftText = "changed unsent draft2801"
                case "replace-same-name":
                    let deleted = replacementStore?.deleteEnvVar(name: name) == true
                    let saved = replacementStore?.saveProvider(name: name,
                        apiKey: "owned replacement fixture credential",
                        baseURL: "https://example.invalid", modelNames: ["owned-model2801"],
                        protocolType: .openaiCompatible) == true
                    gate.recordReplacement(deleted && saved)
                default: chat.cancelComposerCredentialPreflight()
                }
                gate.released.signal()
            }
        }
        chat.submitComposer()
        let deadline = ContinuousClock.now + .seconds(6)
        while (!gate.didEnter || chat.isComposerCredentialPreflightPending) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(gate.didEnter, "the actual Store metadata read must be reached")
        #expect(!gate.onMain, "credential metadata JSON read still ran on the UI actor")
        #expect(!gate.timedOut, "the actual metadata read blocked its UI pulse")
        #expect(!chat.isComposerCredentialPreflightPending)
        if action == "replace-same-name" {
            #expect(gate.didReplace, "the actual owned store replacement must commit")
            #expect(replacementStore?.allEnvVars.first(where: { $0.name == name })?.id != record.id,
                "same-name replacement must have a different actual metadata record identity")
        }
        #expect(chat.messages.allSatisfy { $0.role != .user })
        #expect(bridge.providerRuntimeObservations.isEmpty)
        #expect(engine.toolExecutionFactLedger.facts.isEmpty)

        // The next legal turn uses the intrinsically ready built-in Mock and
        // the same canonical factory; no test engine or route replaces it.
        chat.setProvider(nil)
        #expect(chat.isMockMode)
        chat.draftText = "next legal production turn2801"
        chat.submitComposer()
        let nextDeadline = ContinuousClock.now + .seconds(6)
        while !chat.messages.contains(where: { $0.role == .assistant && $0.content.contains("next legal production turn2801") })
            && ContinuousClock.now < nextDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(chat.messages.filter { $0.role == .user }.count == 1)
        #expect(chat.messages.contains { $0.role == .assistant && $0.content.contains("next legal production turn2801") })
        #expect(bridge.providerRuntimeObservations.count == 1)
        #expect(bridge.providerRuntimeObservations.first?.servedProviderID == "Mock")
        let persisted = try #require(sessions.loadSession(id: id.uuidString))
        #expect(persisted.messages.filter { $0.role == .user }.count == 1)
        #expect(!persisted.messages.contains { $0.content.contains("cancel before Provider construction2801") })
        #expect(engine.toolExecutionFactLedger.facts.isEmpty)
    }
}
