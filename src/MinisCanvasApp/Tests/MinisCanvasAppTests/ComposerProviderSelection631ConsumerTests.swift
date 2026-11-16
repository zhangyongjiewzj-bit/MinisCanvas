import Foundation
import Darwin
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class Provider631Provider: LLMProvider, @unchecked Sendable {
    let name = "provider631-no-transport"
    var model = LLMModel(id: "provider631", displayName: "Local synthetic probe", provider: "test")
    private let lock = NSLock()
    private var counts = [0, 0, 0]
    var calls: [Int] { lock.withLock { counts } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { counts[0] += 1 }
        return LLMResponse(text: "unexpected", stopReason: "end_turn", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        lock.withLock { counts[1] += 1 }
        return LLMResponse(text: "unexpected", stopReason: "end_turn", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        lock.withLock { counts[2] += 1 }
        return AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
private final class Provider631Counts {
    var canvasFactory = 0
    var coordinatorFactory = 0
    var policyRequests: [PendingCommandRequest] = []
}

@Suite("D-COMMAND-06/08 approved selection uses the actual model picker consumer")
@MainActor
struct ComposerProviderSelection631ConsumerTests {
    private struct Fixture {
        let bridge: BridgeStore
        let registry: CommandRegistry
        let center: ComposerCommandAdjudicationCenter
        let counts: Provider631Counts
        let provider: Provider631Provider
        let memory: MemoryStore
        let consumer: MemoryProposalConsumer
        let root: URL
        let sessions: SessionStore
        let lifetime: FixtureLifetime
    }

    @MainActor
    private final class FixtureLifetime {
        let profile: RuntimeIsolationProfile
        private(set) var suites: [String] = []
        var tasks: [Task<Void, Never>] = []
        init(profile: RuntimeIsolationProfile) { self.profile = profile }
        func makeDefaults(_ label: String) throws -> UserDefaults {
            let suite = "COMMAND06-" + label + "-" + UUID().uuidString
            try #require(UserDefaults.standard.persistentDomain(forName: suite) == nil)
            suites.append(suite)
            return try #require(UserDefaults(suiteName: suite))
        }
        func clearSuites() throws {
            for suite in suites {
                UserDefaults.standard.removePersistentDomain(forName: suite)
                try #require(UserDefaults.standard.persistentDomain(forName: suite) == nil)
            }
        }
    }

    private struct FixtureFailures: Error {
        let business: Error?
        let cleanup: Error
    }
    private struct RootNotRemoved: Error {
        let path: String
        let status: Int32
        let code: Int32
    }

    /// Preserve the current Testing task; do not use an NSApp host or a TaskLocal wrapper.
    /// Cleanup executes after every business return/throw, and after every owned worker's value.
    private func withFixture(_ body: @MainActor (Fixture) async throws -> Void) async throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "COMMAND06-provider631", canvasRuntimeState: .disabled)
        let lifetime = FixtureLifetime(profile: profile)
        var active: Fixture?
        let business: Result<Void, Error>
        do {
            try B1ARCHOriginalFixtureSupport.qualifyProfile(profile)
            let value = try await fixture(lifetime: lifetime)
            active = value
            try await body(value)
            business = .success(())
        } catch { business = .failure(error) }
        // Revoke the pending command and original tool waiter, then join all handles.
        // A hung join never reaches destructive cleanup; the outer runner must retain the root.
        active?.center.denyCurrentAdjudication()
        active?.bridge.approvalCenter.dismissPending()
        for task in lifetime.tasks { task.cancel() }
        for task in lifetime.tasks { await task.value }
        let cleanup: Result<Void, Error>
        do {
            try lifetime.clearSuites()
            B1ARCHOriginalFixtureSupport.cleanupProfile(profile)
            var observed = stat(); errno = 0
            let status = lstat(profile.rootDirectory.path, &observed)
            let code = errno
            guard status == -1, code == ENOENT else {
                throw RootNotRemoved(path: profile.rootDirectory.path, status: status, code: code)
            }
            print("COMMAND06_provider631_CLEANUP joined=\(lifetime.tasks.count) exactRootENOENT=true")
            cleanup = .success(())
        } catch { cleanup = .failure(error) }
        switch (business, cleanup) {
        case (.success, .success): return
        case (.failure(let error), .success): throw error
        case (.success, .failure(let error)): throw FixtureFailures(business: nil, cleanup: error)
        case (.failure(let first), .failure(let second)):
            throw FixtureFailures(business: first, cleanup: second)
        }
    }

    private func fixture(lifetime: FixtureLifetime) async throws -> Fixture {
        let profile = lifetime.profile
        let root = profile.rootDirectory
        let defaults = try lifetime.makeDefaults("provider631")
        let environment = EnvVarStore(directory: root.appendingPathComponent("environment"),
            keychain: KeychainStore(backing: InMemoryKeychainBacking()),
            privacyStore: EnvVarPrivacyStore(defaults: defaults))
        let ownedBadges = SessionBadgeStore(directory: root.appendingPathComponent("bridge-badges"))
        let log = LogManager(directory: root.appendingPathComponent("logs"))
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let workflow = WorkflowStore(storeDirectory: root.appendingPathComponent("workflows"))
        let consumer = MemoryProposalConsumer(store: memory)
        let counts = Provider631Counts()
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: log, workflowStore: workflow, sessionBadgeStore: ownedBadges,
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            canvasFactory: { _ in
                counts.canvasFactory += 1
                preconditionFailure("Disabled metadata must never construct CanvasStore")
            },
            agentTaskStore: try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json")),
            contextManifestStore: try ContextManifestStore(persistenceURL: root.appendingPathComponent("contexts.json")),
            memoryStore: memory, memoryProposalConsumer: consumer, commandEnvStore: environment,
            canvasMutationCoordinatorFactory: { _ in
                counts.coordinatorFactory += 1
                preconditionFailure("Disabled metadata must never construct Canvas coordinator")
            },
            providerReadinessStore: readiness,
            taskCenterBindingPersistenceURL: root.appendingPathComponent("bindings.json"),
            canvasFeatureLane: .phase3NonCanvas
        )
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions", isDirectory: true))
        _ = try sessions.createSession(id: UUID().uuidString, title: "Other synthetic owner", projectID: "other-project608")
        _ = try sessions.createSession(id: UUID().uuidString, title: "Synthetic proposal owner", projectID: "owned-project608")
        #expect(bridge.chat.attachPersistence(sessions,
            badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        try #require(bridge.chat.draftStore == nil && bridge.chat.usageStore == nil)
        let backendConfigs = Dictionary(uniqueKeysWithValues: LocalBackendKind.allCases.map {
            ($0, LocalBackendConfig(kind: $0, baseURL: $0.defaultBaseURL, enabled: false))
        })
        let dependencies = CommandDependencies(
            env: environment,
            log: log, backends: LocalBackends(configs: backendConfigs), sessions: sessions,
            memory: memory, workflows: workflow
        )
        // Actual production assembly; no manually manufactured Canvas definitions.
        let registry = AppCommandCatalog.assembled(bridge: bridge, dependencies: dependencies).registry
        let center = ComposerCommandAdjudicationCenter()
        #expect(ProductionCommandRegistryWiring.bind(registry: registry, chat: bridge.chat, center: center))
        let provider = Provider631Provider()
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.compactionProviderOverride = provider
        bridge.chat.configureComposerPolicy(ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: bridge.chat.composerWorkspaceID, revision: "provider631-policy",
            grantEpoch: "provider631-epoch", leaseID: "provider631-lease",
            expiresAt: Date().addingTimeInterval(600), revoked: false, autonomyCeiling: .l3
        ))
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
        center.onPendingTerminalResolution = { [weak bridge] resolution in
            let disposition: ComposerCommandPolicyDecision = resolution.outcome == .approvedExecuted ? .execute : .reject
            _ = bridge?.chat.resolvePendingComposerCommand(requestID: resolution.id, disposition: disposition)
        }
        bridge.chat.onComposerCommandPolicy = { [weak bridge, weak center] request, snapshot in
            counts.policyRequests.append(request)
            guard let bridge, let center else { return .reject }
            return center.evaluate(request: request, snapshot: snapshot, facts: bridge.chat.composerPolicyFacts)
        }
        bridge.chat.localModelCatalogSource = { url in
            #expect(url == ChatStore.LocalReadinessBinding.modelsURL)
            return ["org/model631:1b"]
        }
        let prepared = await bridge.chat.prepareLocalModelSelection(modelID: "org/model631:1b") { true }
        #expect(prepared)
        center.prepareProviderSelection = { [weak bridge] request, snapshot, facts in
            guard let bridge else { throw CommandExecutionError.disabled(commandID: "provider.use", reason: "owner unavailable") }
            return try bridge.prepareComposerProviderSelection(request: request, snapshot: snapshot, facts: facts)
        }
        center.applyApprovedProviderSelection = { [weak bridge] context in
            guard let bridge else { throw CommandExecutionError.disabled(commandID: "provider.use", reason: "owner unavailable") }
            return try bridge.applyApprovedComposerProviderSelection(context)
        }
        return Fixture(bridge: bridge, registry: registry, center: center, counts: counts, provider: provider,
            memory: memory, consumer: consumer, root: root, sessions: sessions, lifetime: lifetime)
    }

    private struct PersistedPending: Decodable {
        let id: UUID
        let commandID: String
        let args: [String: String]
        let requiresPolicyApproval: Bool
    }
    private struct Envelope: Decodable {
        let pending: PersistedPending?
        let receipt: ComposerCommandReceipt?
    }

    private func submit(_ f: Fixture, text: String = "/provider.use local/org/model631:1b") throws -> ComposerCommandReceipt {
        f.bridge.chat.draftText = text
        f.bridge.chat.submitComposer()
        let receipt = try #require(f.bridge.chat.lastComposerCommandReceipt)
        #expect(receipt.commandID == "provider.use" && receipt.disposition == .pending)
        #expect(f.center.pendingAdjudication?.id == receipt.requestID)
        #expect(f.bridge.chat.pendingComposerCommand?.id == receipt.requestID)
        #expect(f.bridge.chat.selectedProviderType == nil && f.bridge.chat.selectedModelID == nil)
        #expect(f.counts.policyRequests.count == 1 && f.counts.policyRequests.first?.args == ["provider_model": "local/org/model631:1b"])
        #expect(f.counts.policyRequests.first?.requiresPolicyApproval == true)
        #expect(f.provider.calls == [0, 0, 0])
        return receipt
    }

    @Test func keyboardBypassSelectsCanonicalProviderWithoutASecondCard() async throws {
        try await withFixture { f in
        let chat = f.bridge.chat
        let owner = try #require(chat.activeSessionID)
        chat.composerPolicySelection.mode = .bypassPermission
        #expect(chat.confirmComposerBypass(for: chat.activeSessionID))
        chat.draftText = "/provider.use local/org/model631:1b"
        chat.submitComposerFromKeyboard()
        let receipt = try #require(chat.lastComposerCommandReceipt)
        #expect(receipt.disposition == .execute)
        #expect(chat.pendingComposerCommand == nil && f.center.pendingAdjudication == nil)
        #expect(f.center.projection?.id == receipt.requestID)
        let session = try #require(f.sessions.loadSession(id: owner.uuidString))
        #expect(session.providerTypeRaw == "local" && session.modelID == "org/model631:1b")
        #expect(chat.lastChatModelApplyReceipt?.modelID == "org/model631:1b")
        #expect(chat.messages.isEmpty && f.provider.calls == [0, 0, 0])
        }
    }

    @Test(arguments: ["/provider.use local/org/model631:1b", "/provider use local/org/model631:1b"])
    func approvalSelectsExactlyOnceThroughPersistentPickerWithoutProvider(text: String) async throws {
        try await withFixture { f in
        let chat = f.bridge.chat
        let owner = try #require(chat.activeSessionID)
        let before = try #require(f.sessions.loadSession(id: owner.uuidString))
        let receipt = try #require(chat.chatModelPickerReceipt(providerID: "local", modelID: "org/model631:1b"))
        let original = try submit(f, text: text)
        #expect(f.center.approveCurrentAdjudication())
        #expect(f.center.lastResolution?.id == original.requestID && f.center.lastResolution?.outcome == .approvedExecuted)
        #expect(chat.selectedProviderType == .local && chat.selectedModelID == "org/model631:1b")
        #expect(chat.lastChatModelApplyReceipt == receipt)
        let after = try #require(f.sessions.loadSession(id: owner.uuidString))
        #expect(after.providerTypeRaw == "local" && after.modelID == "org/model631:1b")
        #expect(after.messages == before.messages && chat.messages.isEmpty)
        #expect(chat.pendingComposerCommand == nil && chat.lastComposerCommandReceipt == original)
        #expect(f.center.projection?.id == original.requestID && f.center.pendingAdjudication == nil)
        let stateURL = f.sessions.directory.appendingPathComponent("chat-composer-command-state.json")
        let bytes = try Data(contentsOf: stateURL)
        let saved = try JSONDecoder().decode(Envelope.self, from: bytes)
        #expect(saved.pending == nil && saved.receipt == original)
        #expect(!f.center.approveCurrentAdjudication())
        #expect(!chat.resolvePendingComposerCommand(requestID: original.requestID, disposition: .execute))
        chat.submitComposer() // empty draft cannot repeat the selection or receipt
        #expect(chat.lastComposerCommandReceipt == original && chat.lastChatModelApplyReceipt == receipt)
        #expect(try Data(contentsOf: stateURL) == bytes)
        chat.newSession()
        chat.switchSession(id: owner)
        #expect(chat.selectedProviderType == .local && chat.selectedModelID == "org/model631:1b")
        let reopenedDefaults = try f.lifetime.makeDefaults("provider631-reopen-success")
        let reopened = ChatStore(
            providerReadinessStore: ProviderReadinessStore(directory: f.root.appendingPathComponent("reopened-readiness")),
            preferencesDefaults: reopenedDefaults,
            logManager: LogManager(directory: f.root.appendingPathComponent("reopen-success-logs"))
        )
        #expect(reopened.attachPersistence(
            f.sessions,
            badgeStore: SessionBadgeStore(directory: f.root.appendingPathComponent("reopen-success-badges"))
        ))
        #expect(reopened.pendingComposerCommand == nil && reopened.lastComposerCommandReceipt == original)
        #expect(reopened.messages.allSatisfy { $0.role != .user })
        let proposals = try f.consumer.envelopes()
        #expect(proposals.isEmpty)
        #expect(f.provider.calls == [0, 0, 0] && f.counts.canvasFactory == 0 && f.counts.coordinatorFactory == 0)
        }
    }

    @Test(arguments: ["deny", "expire", "policy-change", "switch-session", "lease-expired", "revoked", "owner-consumed", "target-replaced", "target-removed"])
    func rejectedOrStaleSelectionCannotApplyOrClaimSuccess(reason: String) async throws {
        try await withFixture { f in
        let chat = f.bridge.chat
        let owner = try #require(chat.activeSessionID)
        let before = try #require(f.sessions.loadSession(id: owner.uuidString))
        let original = try submit(f)
        switch reason {
        case "deny": f.center.denyCurrentAdjudication()
        case "expire": f.center.expireCurrentAdjudication()
        case "owner-consumed":
            #expect(chat.resolvePendingComposerCommand(requestID: original.requestID, disposition: .reject))
            #expect(!f.center.approveCurrentAdjudication())
        case "policy-change", "lease-expired", "revoked":
            let old = chat.composerPolicyFacts
            chat.configureComposerPolicy(ComposerPolicyFactSource(
                knownCapabilities: old.knownCapabilities, grantedCapabilities: old.grantedCapabilities,
                allowedWriteRoots: old.allowedWriteRoots, workspaceID: old.workspaceID,
                revision: reason == "policy-change" ? "changed-policy631" : old.revision,
                grantEpoch: old.grantEpoch, leaseID: old.leaseID,
                expiresAt: reason == "lease-expired" ? Date().addingTimeInterval(-1) : old.expiresAt,
                revoked: reason == "revoked"))
            #expect(!f.center.approveCurrentAdjudication())
        case "target-replaced", "target-removed":
            if reason == "target-removed" { chat.localModelCatalogSource = { _ in [] } }
            let prepared = await chat.prepareLocalModelSelection(modelID: "org/model631:1b") { true }
            #expect(prepared == (reason == "target-replaced"))
            #expect(!f.center.approveCurrentAdjudication())
        default:
            let other = try #require(chat.sessions.first(where: { $0.id != owner }))
            chat.switchSession(id: other.id)
            #expect(!f.center.approveCurrentAdjudication())
        }
        let terminal = try #require(f.center.lastResolution)
        #expect(terminal.id == original.requestID && terminal.outcome != .approvedExecuted)
        if reason == "deny" { #expect(terminal.outcome == .deniedByUser) }
        else if reason == "expire" { #expect(terminal.outcome == .expiredUnanswered) }
        else { #expect(terminal.outcome == .rejectedByPolicy("命令 provider.use 当前不可用：原提交策略、会话或目标已改变")) }
        #expect(chat.lastChatModelApplyReceipt == nil && chat.selectedModelID == nil)
        #expect(chat.lastComposerCommandReceipt == original && !f.center.approveCurrentAdjudication())
        let after = try #require(f.sessions.loadSession(id: owner.uuidString))
        #expect(after.providerTypeRaw == before.providerTypeRaw && after.modelID == before.modelID && after.messages == before.messages)
        #expect(f.provider.calls == [0, 0, 0])
        }
    }

    @Test(arguments: ["local/not-installed", "local/", "local", "missing/org/model631:1b"])
    func invalidOrUnreadyTargetIsTypedRejectedBeforeApproval(input: String) async throws {
        try await withFixture { f in
        f.bridge.chat.draftText = "/provider.use " + input
        f.bridge.chat.submitComposer()
        let receipt = try #require(f.bridge.chat.lastComposerCommandReceipt)
        #expect(receipt.disposition == .reject && receipt.commandID == "provider.use")
        #expect(f.center.lastResolution?.outcome == .unavailableExecutor("命令 provider.use 当前不可用：目标必须是当前可选择的 provider/model"))
        #expect(f.center.pendingAdjudication == nil && f.bridge.chat.pendingComposerCommand == nil)
        #expect(!f.center.approveCurrentAdjudication() && f.bridge.chat.lastChatModelApplyReceipt == nil)
        #expect(f.provider.calls == [0, 0, 0] && f.bridge.chat.messages.isEmpty)
        }
    }

    @Test func restoredPendingWithoutFrozenTargetCannotSelectOrReplay() async throws {
        try await withFixture { f in
        let original = try submit(f)
        let defaults = try f.lifetime.makeDefaults("provider631-restored")
        let restored = ChatStore(providerReadinessStore: ProviderReadinessStore(directory: f.root.appendingPathComponent("restored-readiness")),
            preferencesDefaults: defaults,
            logManager: LogManager(directory: f.root.appendingPathComponent("restored-logs")))
        #expect(restored.attachPersistence(f.sessions,
            badgeStore: SessionBadgeStore(directory: f.root.appendingPathComponent("restored-badges"))))
        let pending = try #require(restored.pendingComposerCommand)
        let center = ComposerCommandAdjudicationCenter()
        #expect(ProductionCommandRegistryWiring.bind(registry: f.registry, chat: restored, center: center))
        var writerCalls = 0
        center.prepareProviderSelection = { request, snapshot, facts in
            try f.bridge.prepareComposerProviderSelection(request: request, snapshot: snapshot, facts: facts)
        }
        center.applyApprovedProviderSelection = { context in
            writerCalls += 1
            return try f.bridge.applyApprovedComposerProviderSelection(context)
        }
        center.onPendingTerminalResolution = { result in
            #expect(result.id == original.requestID)
            #expect(restored.resolvePendingComposerCommand(requestID: result.id, disposition: .reject))
        }
        center.adoptRestoredPending(pending, sessionID: original.sessionID)
        #expect(writerCalls == 0 && restored.pendingComposerCommand?.id == original.requestID)
        #expect(!center.approveCurrentAdjudication())
        #expect(center.lastResolution?.outcome == .rejectedByPolicy("原提交策略与目标快照不可用"))
        #expect(writerCalls == 0 && restored.pendingComposerCommand == nil && restored.lastComposerCommandReceipt == original)
        #expect(f.provider.calls == [0, 0, 0] && f.bridge.chat.lastChatModelApplyReceipt == nil)
        f.center.denyCurrentAdjudication()
        }
    }
}
