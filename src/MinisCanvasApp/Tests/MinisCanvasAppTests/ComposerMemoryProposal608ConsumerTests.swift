import Foundation
import Darwin
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class Memory608Provider: LLMProvider, @unchecked Sendable {
    let name = "memory608-no-transport"
    var model = LLMModel(id: "memory608", displayName: "Local synthetic probe", provider: "test")
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
private final class Memory608Counts {
    var canvasFactory = 0
    var coordinatorFactory = 0
    var policyRequests: [PendingCommandRequest] = []
}

@MainActor
private final class PresentedApproval1056Probe {
    var finished = false
    var executions = 0
    var result: String?
    var receipts: [ApprovalReceipt] = []
}

@Suite("D-COMMAND-06/08 approved scoped proposal uses the canonical consumer")
@MainActor
struct ComposerMemoryProposal608ConsumerTests {
    private struct Fixture {
        let bridge: BridgeStore
        let registry: CommandRegistry
        let center: ComposerCommandAdjudicationCenter
        let counts: Memory608Counts
        let provider: Memory608Provider
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
        let observationID = UUID().uuidString
        var observationKind: String?
        var observationProbes: [PresentedApproval1056Probe] = []
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

    private static func observeWait(_ phase: String, fixture f: Fixture, index: Int = -1) {
        guard let kind = f.lifetime.observationKind else { return }
        let prompt = f.bridge.approvalCenter
        let finished = f.lifetime.observationProbes.map { $0.finished ? "1" : "0" }.joined(separator: ",")
        let diagnostic = prompt.lastDiagnostic.map { String(describing: $0.code) } ?? "none"
        print("MEMORY608_WAIT id=\(f.lifetime.observationID) kind=\(kind) phase=\(phase) index=\(index) finished=[\(finished)] queued=\(prompt.approvalQueue.queuedRequests.count) pending=\(prompt.pendingRequest != nil) diagnostic=\(diagnostic)")
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
            label: "COMMAND06-memory608", canvasRuntimeState: .disabled)
        let lifetime = FixtureLifetime(profile: profile)
        var active: Fixture?
        let business: Result<Void, Error>
        do {
            try B1ARCHOriginalFixtureSupport.qualifyProfile(profile)
            let value = try fixture(lifetime: lifetime)
            active = value
            try await body(value)
            business = .success(())
        } catch { business = .failure(error) }
        // Revoke the pending command and original tool waiter, then join all handles.
        // A hung join never reaches destructive cleanup; the outer runner must retain the root.
        if let active { Self.observeWait("fixture-cancel-before", fixture: active) }
        active?.center.denyCurrentAdjudication()
        active?.bridge.approvalCenter.dismissPending()
        for task in lifetime.tasks { task.cancel() }
        if let active { Self.observeWait("fixture-cancel-after", fixture: active) }
        for (index, task) in lifetime.tasks.enumerated() {
            if let active { Self.observeWait("fixture-join-before", fixture: active, index: index) }
            await task.value
            if let active { Self.observeWait("fixture-join-after", fixture: active, index: index) }
        }
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
            print("COMMAND06_memory608_CLEANUP joined=\(lifetime.tasks.count) exactRootENOENT=true")
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

    private func fixture(lifetime: FixtureLifetime) throws -> Fixture {
        let profile = lifetime.profile
        let root = profile.rootDirectory
        let defaults = try lifetime.makeDefaults("memory608")
        let environment = EnvVarStore(directory: root.appendingPathComponent("environment"),
            keychain: KeychainStore(backing: InMemoryKeychainBacking()),
            privacyStore: EnvVarPrivacyStore(defaults: defaults))
        let ownedBadges = SessionBadgeStore(directory: root.appendingPathComponent("bridge-badges"))
        let log = LogManager(directory: root.appendingPathComponent("logs"))
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let workflow = WorkflowStore(storeDirectory: root.appendingPathComponent("workflows"))
        let consumer = MemoryProposalConsumer(store: memory)
        _ = try consumer.grantCandidateSubmission(
            sourceID: "composer-command",
            reason: "test fixture explicit grant"
        )
        let counts = Memory608Counts()
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
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness")),
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
        let provider = Memory608Provider()
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.compactionProviderOverride = provider
        bridge.chat.configureComposerPolicy(ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: bridge.chat.composerWorkspaceID, revision: "memory608-policy",
            grantEpoch: "memory608-epoch", leaseID: "memory608-lease",
            expiresAt: Date().addingTimeInterval(600), revoked: false, autonomyCeiling: .l3
        ))
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
        center.memoryProposalScopeProvider = { [weak bridge] in bridge?.chat.activeMemoryScope }
        center.submitApprovedMemoryProposal = { [weak bridge] context in
            guard let bridge else { throw CommandExecutionError.disabled(commandID: "memory.propose", reason: "owner unavailable") }
            return try bridge.submitApprovedComposerMemoryProposal(context)
        }
        center.onPendingTerminalResolution = { [weak bridge] resolution in
            let disposition: ComposerCommandPolicyDecision = resolution.outcome == .approvedExecuted ? .execute : .reject
            _ = bridge?.chat.resolvePendingComposerCommand(requestID: resolution.id, disposition: disposition)
        }
        bridge.chat.onComposerCommandPolicy = { [weak bridge, weak center] request, snapshot in
            counts.policyRequests.append(request)
            guard let bridge, let center else { return .reject }
            return center.evaluate(request: request, snapshot: snapshot, facts: bridge.chat.composerPolicyFacts)
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

    private func submit(_ f: Fixture) throws -> ComposerCommandReceipt {
        f.bridge.chat.draftText = "/memory.propose keep this scoped proposal"
        f.bridge.chat.submitComposer()
        let receipt = try #require(f.bridge.chat.lastComposerCommandReceipt)
        #expect(receipt.commandID == "memory.propose" && receipt.disposition == .pending)
        #expect(f.center.pendingAdjudication?.id == receipt.requestID)
        #expect(f.bridge.chat.pendingComposerCommand?.id == receipt.requestID)
        let proposals = try f.consumer.envelopes()
        let facts = try f.memory.facts()
        #expect(proposals.isEmpty && facts.isEmpty)
        #expect(f.counts.policyRequests.count == 1 && f.counts.policyRequests.first?.requiresPolicyApproval == true)
        return receipt
    }

    @Test func keyboardBypassOnlySubmitsAProposalForReview() async throws {
        try await withFixture { f in
        let chat = f.bridge.chat
        chat.composerPolicySelection.mode = .bypassPermission
        #expect(chat.confirmComposerBypass(for: chat.activeSessionID))
        chat.draftText = "/memory.propose keep this scoped proposal"
        chat.submitComposerFromKeyboard()
        let receipt = try #require(chat.lastComposerCommandReceipt)
        #expect(receipt.disposition == .execute)
        #expect(chat.pendingComposerCommand == nil && f.center.pendingAdjudication == nil)
        #expect(f.center.projection?.id == receipt.requestID)
        let proposals = try f.consumer.envelopes()
        let proposal = try #require(proposals.first)
        #expect(proposals.count == 1 && proposal.proposal.proposalID == receipt.requestID.uuidString)
        #expect(proposal.state == .proposed && proposal.approvalReceipt == nil)
        #expect(try f.memory.facts().isEmpty)
        #expect(f.provider.calls == [0, 0, 0])
        }
    }

    @Test func approvedProposalIsDurableOnceWithoutTranscriptProviderOrFactActivation() async throws {
        try await withFixture { f in
        let chat = f.bridge.chat
        let owner = try #require(chat.activeSessionID)
        let originalScope = try #require(chat.activeMemoryScope)
        let before = chat.messages
        let persistedBefore = try #require(f.sessions.loadSession(id: owner.uuidString))
        #expect(f.bridge.composerCommandReadinessObservation(for: "memory.propose") == .noKnownBlocker)
        let original = try submit(f)
        #expect(f.center.approveCurrentAdjudication())
        let result = try #require(f.center.lastResolution)
        #expect(result.id == original.requestID && result.outcome == .approvedExecuted)
        #expect(f.center.projection?.id == original.requestID)
        #expect(chat.pendingComposerCommand == nil && f.center.pendingAdjudication == nil)
        #expect(chat.lastComposerCommandReceipt == original)
        let proposals = try f.consumer.envelopes()
        let proposal = try #require(proposals.first)
        #expect(proposals.count == 1 && proposal.proposal.proposalID == original.requestID.uuidString)
        #expect(proposal.state == .proposed && proposal.approvalReceipt == nil)
        #expect(proposal.proposal.memoryScope == originalScope && proposal.binding?.sessionID == owner.uuidString)
        #expect(proposal.text == "keep this scoped proposal")
        #expect(proposal.sourceRef == "composer://command/\(original.requestID.uuidString)")
        let facts = try f.memory.facts()
        #expect(facts.isEmpty)
        #expect(chat.messages == before && f.provider.calls == [0, 0, 0])
        let persistedAfter = try #require(f.sessions.loadSession(id: owner.uuidString))
        #expect(persistedAfter.messages == persistedBefore.messages)
        let stateURL = f.sessions.directory.appendingPathComponent("chat-composer-command-state.json")
        let bytes = try Data(contentsOf: stateURL)
        let saved = try JSONDecoder().decode(Envelope.self, from: bytes)
        #expect(saved.pending == nil && saved.receipt == original)
        #expect(!f.center.approveCurrentAdjudication())
        #expect(!chat.resolvePendingComposerCommand(requestID: original.requestID, disposition: .execute))
        chat.submitComposer() // Empty draft cannot consume or replay the command again.
        #expect(chat.lastComposerCommandReceipt == original)
        #expect(try Data(contentsOf: stateURL) == bytes)
        let reopened = MemoryProposalConsumer(store: MemoryStore(directory: f.memory.directory))
        let reopenedProposals = try reopened.envelopes()
        #expect(reopenedProposals == proposals && f.provider.calls == [0, 0, 0])
        let reopenedDefaults = try f.lifetime.makeDefaults("memory608-reopen")
        let reopenedChat = ChatStore(providerReadinessStore: ProviderReadinessStore(directory: f.root.appendingPathComponent("reopened-readiness")),
            preferencesDefaults: reopenedDefaults,
            logManager: LogManager(directory: f.root.appendingPathComponent("reopen-logs")))
        #expect(reopenedChat.attachPersistence(f.sessions,
            badgeStore: SessionBadgeStore(directory: f.root.appendingPathComponent("reopen-badges"))))
        #expect(reopenedChat.pendingComposerCommand == nil && reopenedChat.lastComposerCommandReceipt == original)
        #expect(f.counts.canvasFactory == 0 && f.counts.coordinatorFactory == 0)
        }
    }

    @Test(arguments: ["deny", "expire", "policy-change", "switch-session", "lease-expired", "revoked", "owner-consumed"])
    func rejectedOrStaleApprovalNeverWritesOrReportsSuccess(reason: String) async throws {
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
                revision: reason == "policy-change" ? "changed-policy608" : old.revision,
                grantEpoch: old.grantEpoch, leaseID: old.leaseID,
                expiresAt: reason == "lease-expired" ? Date().addingTimeInterval(-1) : old.expiresAt,
                revoked: reason == "revoked"))
            #expect(!f.center.approveCurrentAdjudication())
        default:
            let other = try #require(chat.sessions.first(where: { $0.id != owner }))
            chat.switchSession(id: other.id)
            #expect(chat.activeSessionID == other.id)
            #expect(!f.center.approveCurrentAdjudication())
        }
        let terminal = try #require(f.center.lastResolution)
        #expect(terminal.id == original.requestID && terminal.outcome != .approvedExecuted)
        if reason == "deny" { #expect(terminal.outcome == .deniedByUser) }
        else if reason == "expire" { #expect(terminal.outcome == .expiredUnanswered) }
        else { #expect(terminal.outcome == .rejectedByPolicy("命令 memory.propose 当前不可用：原提交策略、会话或项目范围已改变")) }
        let proposals = try f.consumer.envelopes()
        let facts = try f.memory.facts()
        #expect(proposals.isEmpty && facts.isEmpty && f.provider.calls == [0, 0, 0])
        #expect(f.center.pendingAdjudication == nil && !f.center.approveCurrentAdjudication())
        #expect(chat.lastComposerCommandReceipt == original)
        let persistedOwner = try #require(f.sessions.loadSession(id: owner.uuidString))
        #expect(persistedOwner.messages == before.messages)
        }
    }

    @Test func restoredPendingWithoutItsOriginalAuthorityCannotWriteOrReplay() async throws {
        try await withFixture { f in
        let original = try submit(f)
        let defaults = try f.lifetime.makeDefaults("memory608-restored")
        let restored = ChatStore(providerReadinessStore: ProviderReadinessStore(directory: f.root.appendingPathComponent("restored-readiness")),
            preferencesDefaults: defaults,
            logManager: LogManager(directory: f.root.appendingPathComponent("restored-logs")))
        #expect(restored.attachPersistence(f.sessions,
            badgeStore: SessionBadgeStore(directory: f.root.appendingPathComponent("restored-badges"))))
        let pending = try #require(restored.pendingComposerCommand)
        #expect(pending.id == original.requestID && restored.lastComposerCommandReceipt == original)
        let center = ComposerCommandAdjudicationCenter()
        #expect(ProductionCommandRegistryWiring.bind(registry: f.registry, chat: restored, center: center))
        var writerCalls = 0
        center.memoryProposalScopeProvider = { f.bridge.chat.activeMemoryScope }
        center.submitApprovedMemoryProposal = { context in
            writerCalls += 1
            return try f.bridge.submitApprovedComposerMemoryProposal(context)
        }
        center.onPendingTerminalResolution = { result in
            #expect(result.id == original.requestID)
            #expect(restored.resolvePendingComposerCommand(requestID: result.id, disposition: .reject))
        }
        center.adoptRestoredPending(pending, sessionID: original.sessionID)
        #expect(writerCalls == 0 && restored.pendingComposerCommand?.id == original.requestID)
        #expect(!center.approveCurrentAdjudication())
        #expect(center.lastResolution?.outcome == .rejectedByPolicy("原提交策略与范围快照不可用"))
        #expect(writerCalls == 0 && restored.pendingComposerCommand == nil)
        #expect(restored.lastComposerCommandReceipt == original)
        let proposals = try f.consumer.envelopes()
        #expect(proposals.isEmpty && f.provider.calls == [0, 0, 0])
        // Resolve the first process's in-memory card without executing it.
        f.center.denyCurrentAdjudication()
        }
    }

    // Reuse the existing owned production Registry/Bridge/SessionStore fixture.
    // The target is produced by the real ApprovalGate, then dispatched through
    // PolicyRuntimeBinding and BuiltinToolExecutor, not a command-handler stub.
    private func bindPresentedApproval1056(_ f: Fixture) {
        f.center.preparePresentedToolApproval = { [weak bridge = f.bridge] request, snapshot, facts in
            guard let bridge else { throw CommandExecutionError.disabled(commandID: "approve", reason: "owner unavailable") }
            return try bridge.prepareComposerPresentedToolApproval(request: request, snapshot: snapshot, facts: facts)
        }
        f.center.applyPresentedToolApproval = { [weak bridge = f.bridge] context in
            guard let bridge else { throw CommandExecutionError.disabled(commandID: "approve", reason: "owner unavailable") }
            return try bridge.applyComposerPresentedToolApproval(context)
        }
    }

    private func submitPresentedApproval1056(_ f: Fixture) throws -> ComposerCommandReceipt {
        f.bridge.chat.draftText = "/approve"
        f.bridge.chat.submitComposer()
        let receipt = try #require(f.bridge.chat.lastComposerCommandReceipt)
        #expect(receipt.commandID == "approve" && receipt.disposition == .pending)
        #expect(f.center.pendingAdjudication?.id == receipt.requestID)
        #expect(f.bridge.chat.pendingComposerCommand?.id == receipt.requestID)
        return receipt
    }

    private func observePresentedApproval1056(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        return predicate()
    }

    private func targetContext1056(_ f: Fixture, tool: String, target: URL,
                                   sessionID: String? = nil) throws -> ApprovalAuthorizationContext {
        let session = try #require(f.bridge.chat.activeSessionID)
        let input: [String: Any] = tool == "file_read"
            ? ["path": target.path] : ["path": target.path, "content": "owned1056-output"]
        let digest = try #require(ApprovalAuthorizationContext.payloadDigest(for: input))
        let facts = f.bridge.chat.composerPolicyFacts
        let unique = UUID().uuidString
        return ApprovalAuthorizationContext(actorID: "approval1056-" + unique,
            sessionID: sessionID ?? session.uuidString, turnID: 1,
            taskID: "task1056-" + unique, runID: "run1056-" + unique,
            attemptID: "attempt1056-" + unique, effectID: "call1056-" + unique,
            scope: "request", payloadDigest: digest, expiresAt: Date().addingTimeInterval(300),
            policyRevision: facts.revision, grantEpoch: facts.grantEpoch, toolName: tool)
    }

    private func beginTarget1056(_ f: Fixture, target: URL, tool: String,
                                context: ApprovalAuthorizationContext,
                                probe: PresentedApproval1056Probe) -> Task<Void, Never> {
        let center = f.bridge.approvalCenter
        let root = f.root
        if f.lifetime.observationKind != nil { f.lifetime.observationProbes.append(probe) }
        let observation = f.lifetime.observationKind.map { "id=\(f.lifetime.observationID) kind=\($0)" }
        let task = Task { @MainActor in
            if let observation {
                print("MEMORY608_WAIT \(observation) phase=task-start finished=\(probe.finished) queued=\(center.approvalQueue.queuedRequests.count) pending=\(center.pendingRequest != nil)")
            }
            do {
                let result = try await Self.executeTarget1056(center: center, root: root,
                    target: target, tool: tool, context: context, probe: probe, observation: observation)
                probe.result = result
                probe.executions += 1
            } catch { probe.result = nil }
            probe.finished = true
            if let observation {
                print("MEMORY608_WAIT \(observation) phase=task-finished finished=\(probe.finished) queued=\(center.approvalQueue.queuedRequests.count) pending=\(center.pendingRequest != nil)")
            }
        }
        f.lifetime.tasks.append(task)
        return task
    }

    private nonisolated static func executeTarget1056(
        center: ApprovalPromptCenter, root: URL, target: URL, tool: String,
        context: ApprovalAuthorizationContext, probe: PresentedApproval1056Probe, observation: String?
    ) async throws -> String {
        let input: [String: Any] = tool == "file_read"
            ? ["path": target.path] : ["path": target.path, "content": "owned1056-output"]
        let gate = ApprovalGate(policyByTool: [tool: .alwaysAsk],
            delegate: ApprovalPromptDelegate(center: center),
            onApprovalReceipt: { receipt in await MainActor.run { probe.receipts.append(receipt) } })
        if let observation { print("MEMORY608_WAIT \(observation) phase=gate-before") }
        do {
            _ = try await gate.gate(tool: tool, input: input, context: context)
            if let observation { print("MEMORY608_WAIT \(observation) phase=gate-after") }
        } catch {
            if let observation { print("MEMORY608_WAIT \(observation) phase=gate-error type=\(String(reflecting: type(of: error)))") }
            throw error
        }
        let now = Date()
        let goal = GoalEnvelope(scopeID: context.sessionID, allowedCapabilities: [tool],
            fileRoots: [root.path], budget: 10, deadline: context.expiresAt,
            concurrencyLimit: 1, autonomyLevel: .l2, creatorID: context.actorID, createdAt: now)
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
            issuedAt: now, expiresAt: goal.deadline)
        return try await PolicyRuntimeBinding(goal: goal, lease: lease)
            .wrap(BuiltinToolExecutor(allowedRoot: root)).execute(name: tool, input: input)
    }

    @Test(arguments: ["file_read", "file_write"])
    func approveConsumesTheOriginalGateWithIndependentL3Steps1056(tool: String) async throws {
        try await withFixture { f in
        bindPresentedApproval1056(f)
        let owner = try #require(f.bridge.chat.activeSessionID)
        let before = try #require(f.sessions.loadSession(id: owner.uuidString))
        let beforeChat = f.bridge.chat.messages
        let target = f.root.appendingPathComponent("target1056.txt")
        if tool == "file_read" { try Data("owned1056-source".utf8).write(to: target) }
        let context = try targetContext1056(f, tool: tool, target: target)
        let probe = PresentedApproval1056Probe()
        let task = beginTarget1056(f, target: target, tool: tool, context: context, probe: probe)
        defer { task.cancel(); f.bridge.approvalCenter.dismissPending() }
        #expect(await observePresentedApproval1056 { f.bridge.approvalCenter.pendingRequest != nil })
        let original = try #require(f.bridge.approvalCenter.pendingRequest)
        #expect(original.binding?.identityDigest == context.identityDigest)
        #expect(original.requiresSecondConfirmation == (tool == "file_write"))
        #expect(f.bridge.composerCommandReadinessObservation(for: "approve") == .noKnownBlocker)
        let first = try submitPresentedApproval1056(f)
        #expect(f.bridge.approvalCenter.pendingRequest == original) // The command card never re-presents a target.
        #expect(f.center.pendingAdjudication?.policySummary.contains("首次允许") == true)
        #expect(probe.executions == 0 && probe.receipts.isEmpty)
        try await Task.sleep(for: .milliseconds(500))
        try #require(f.bridge.approvalCenter.pendingRequest == original
            && !f.bridge.approvalCenter.awaitingConfirmation)
        #expect(f.center.approveCurrentAdjudication())
        #expect(f.center.lastResolution?.id == first.requestID)
        #expect(f.center.projection?.id == first.requestID)
        #expect(f.bridge.chat.lastComposerCommandReceipt == first)
        #expect(!f.center.approveCurrentAdjudication())
        if tool == "file_write" {
            #expect(f.bridge.approvalCenter.pendingRequest == original)
            #expect(f.bridge.approvalCenter.awaitingConfirmation && !probe.finished)
            #expect(probe.executions == 0 && probe.receipts.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: target.path))
            #expect(f.center.projection?.text.contains("尚未允许工具执行") == true)
            let second = try submitPresentedApproval1056(f)
            #expect(second.requestID != first.requestID)
            #expect(f.center.pendingAdjudication?.policySummary.contains("独立第二次确认") == true)
            #expect(f.bridge.approvalCenter.pendingRequest == original)
            try await Task.sleep(for: .milliseconds(500))
            try #require(f.bridge.approvalCenter.pendingRequest == original
                && f.bridge.approvalCenter.awaitingConfirmation)
            #expect(f.center.approveCurrentAdjudication())
            #expect(!f.center.approveCurrentAdjudication())
        }
        #expect(await observePresentedApproval1056 { probe.finished })
        guard probe.finished else { return }
        await task.value
        #expect(probe.executions == 1 && probe.result != nil)
        if tool == "file_read" { #expect(probe.result?.contains("owned1056-source") == true) }
        #expect(f.bridge.approvalCenter.pendingRequest == nil)
        #expect(probe.receipts.count == 1 && probe.receipts.first?.identityDigest == context.identityDigest)
        #expect(try Data(contentsOf: target) == Data((tool == "file_write" ? "owned1056-output" : "owned1056-source").utf8))
        #expect(f.bridge.chat.messages == beforeChat)
        let expectedCommandReceipt = try #require(f.bridge.chat.lastComposerCommandReceipt)
        #expect(f.center.projection?.id == expectedCommandReceipt.requestID)
        #expect(f.center.lastResolution?.id == expectedCommandReceipt.requestID)
        #expect(f.bridge.chat.pendingComposerCommand == nil)
        let reopenedDefaults = try f.lifetime.makeDefaults("approval1056-reopen-success")
        let reopenedChat = ChatStore(
            providerReadinessStore: ProviderReadinessStore(directory: f.root.appendingPathComponent("reopened-readiness")),
            preferencesDefaults: reopenedDefaults,
            logManager: LogManager(directory: f.root.appendingPathComponent("approval1056-reopen-logs"))
        )
        #expect(reopenedChat.attachPersistence(
            f.sessions,
            badgeStore: SessionBadgeStore(directory: f.root.appendingPathComponent("approval1056-reopen-badges"))
        ))
        #expect(reopenedChat.pendingComposerCommand == nil)
        #expect(reopenedChat.lastComposerCommandReceipt == expectedCommandReceipt)
        #expect(reopenedChat.messages.allSatisfy { $0.role != .user })
        let after = try #require(f.sessions.loadSession(id: owner.uuidString))
        #expect(after.messages == before.messages)
        #expect(f.provider.calls == [0, 0, 0] && f.counts.canvasFactory == 0 && f.counts.coordinatorFactory == 0)
        #expect(try f.consumer.envelopes().isEmpty && f.memory.facts().isEmpty)
        }
    }

    @Test(arguments: ["deny", "command-expiry", "revoked", "facts-expired", "changed-policy",
                      "session-switch", "target-expiry", "target-ABA", "stage-change"])
    func rejectedOrChangedApprovalCannotActOnTheOriginalOrReplacement1056(reason: String) async throws {
        try await withFixture { f in
        bindPresentedApproval1056(f)
        let target = f.root.appendingPathComponent("negative1056.txt")
        let context = try targetContext1056(f, tool: "file_write", target: target)
        let probe = PresentedApproval1056Probe()
        let task = beginTarget1056(f, target: target, tool: "file_write", context: context, probe: probe)
        var replacementTask: Task<Void, Never>?
        let replacement = PresentedApproval1056Probe()
        defer { task.cancel(); replacementTask?.cancel(); f.bridge.approvalCenter.dismissPending() }
        #expect(await observePresentedApproval1056 { f.bridge.approvalCenter.pendingRequest != nil })
        let originalTarget = try #require(f.bridge.approvalCenter.pendingRequest)
        let messages = f.bridge.chat.messages
        let command = try submitPresentedApproval1056(f)
        switch reason {
        case "deny": f.center.denyCurrentAdjudication()
        case "command-expiry": f.center.expireCurrentAdjudication()
        case "session-switch": f.bridge.chat.newSession()
        case "target-expiry":
            f.bridge.approvalCenter.expirePending()
            await task.value
        case "target-ABA":
            f.bridge.approvalCenter.dismissPending()
            await task.value
            replacementTask = beginTarget1056(f, target: target, tool: "file_write", context: context, probe: replacement)
            #expect(await observePresentedApproval1056 { f.bridge.approvalCenter.pendingRequest != nil })
            #expect(f.bridge.approvalCenter.pendingRequest == originalTarget) // Same full public request; different private nonce.
        case "stage-change": f.bridge.approvalCenter.actionsForPresentedRequest().approve()
        default:
            let old = f.bridge.chat.composerPolicyFacts
            f.bridge.chat.configureComposerPolicy(ComposerPolicyFactSource(
                knownCapabilities: old.knownCapabilities, grantedCapabilities: old.grantedCapabilities,
                allowedWriteRoots: old.allowedWriteRoots, workspaceID: old.workspaceID,
                revision: reason == "changed-policy" ? "changed1056" : old.revision,
                grantEpoch: old.grantEpoch, leaseID: old.leaseID,
                expiresAt: reason == "facts-expired" ? Date().addingTimeInterval(-1) : old.expiresAt,
                revoked: reason == "revoked", autonomyCeiling: old.autonomyCeiling))
        }
        #expect(!f.center.approveCurrentAdjudication())
        #expect(f.center.lastResolution?.id == command.requestID)
        if reason == "deny" { #expect(f.center.lastResolution?.outcome == .deniedByUser) }
        else if reason == "command-expiry" { #expect(f.center.lastResolution?.outcome == .expiredUnanswered) }
        else if case .some(.rejectedByPolicy(_)) = f.center.lastResolution?.outcome { }
        else { Issue.record("Changed target/facts must be a typed policy rejection") }
        #expect(probe.executions == 0 && replacement.executions == 0)
        #expect(probe.receipts.isEmpty && replacement.receipts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(f.provider.calls == [0, 0, 0] && f.counts.canvasFactory == 0 && f.counts.coordinatorFactory == 0)
        if reason == "target-ABA" { #expect(f.bridge.approvalCenter.lastDiagnostic?.code == .requestMismatch) }
        if reason != "session-switch" { #expect(f.bridge.chat.messages == messages) }
        f.bridge.approvalCenter.dismissPending()
        await task.value
        if let replacementTask { await replacementTask.value }
        #expect(probe.executions == 0 && replacement.executions == 0)
        }
    }

    @Test(arguments: ["missing", "foreign", "restored"])
    func absentForeignOrRestoredTargetCannotGainCommandAuthority1056(kind: String) async throws {
        try await withFixture { f in
        f.lifetime.observationKind = kind
        Self.observeWait("body-start", fixture: f)
        bindPresentedApproval1056(f)
        let target = f.root.appendingPathComponent("unavailable1056.txt")
        let probe = PresentedApproval1056Probe()
        var task: Task<Void, Never>?
        defer {
            Self.observeWait("body-defer-before", fixture: f)
            task?.cancel(); f.bridge.approvalCenter.dismissPending()
            Self.observeWait("body-defer-after", fixture: f)
        }
        if kind != "missing" {
            Self.observeWait("target-context-require-before", fixture: f)
            let context = try targetContext1056(f, tool: "file_write", target: target,
                sessionID: kind == "foreign" ? "owned-foreign1056-" + UUID().uuidString : nil)
            Self.observeWait("target-context-require-after", fixture: f)
            task = beginTarget1056(f, target: target, tool: "file_write", context: context, probe: probe)
            #expect(await observePresentedApproval1056 { f.bridge.approvalCenter.pendingRequest != nil })
        }
        let originalMessages = f.bridge.chat.messages
        if kind == "restored" {
            let command = try submitPresentedApproval1056(f)
            Self.observeWait("restored-require-before", fixture: f)
            let pending = try #require(f.bridge.chat.pendingComposerCommand)
            Self.observeWait("restored-require-after", fixture: f)
            let restored = ComposerCommandAdjudicationCenter()
            restored.preparePresentedToolApproval = f.center.preparePresentedToolApproval
            restored.applyPresentedToolApproval = f.center.applyPresentedToolApproval
            restored.onPendingTerminalResolution = { resolution in
                #expect(resolution.id == command.requestID)
                #expect(f.bridge.chat.resolvePendingComposerCommand(requestID: resolution.id, disposition: .reject))
            }
            restored.adoptRestoredPending(pending, sessionID: command.sessionID)
            #expect(!restored.approveCurrentAdjudication())
            #expect(restored.lastResolution?.outcome == .rejectedByPolicy("原工具审批目标不可用"))
            #expect(f.bridge.approvalCenter.pendingRequest != nil)
            f.center.denyCurrentAdjudication()
        } else {
            f.bridge.chat.draftText = "/approve"
            f.bridge.chat.submitComposer()
            Self.observeWait("receipt-require-before", fixture: f)
            let receipt = try #require(f.bridge.chat.lastComposerCommandReceipt)
            Self.observeWait("receipt-require-after", fixture: f)
            #expect(receipt.commandID == "approve" && receipt.disposition == .reject)
            let reason = CommandExecutionError.disabled(commandID: "approve",
                reason: "当前会话没有同策略身份的有效工具审批请求").errorDescription
            #expect(f.center.lastResolution?.outcome == .unavailableExecutor(reason))
            #expect(f.center.pendingAdjudication == nil && f.bridge.chat.pendingComposerCommand == nil)
            #expect(!f.center.approveCurrentAdjudication())
        }
        #expect(probe.executions == 0 && probe.receipts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(f.bridge.chat.messages == originalMessages && f.provider.calls == [0, 0, 0])
        f.bridge.approvalCenter.dismissPending()
        if let task {
            Self.observeWait("body-join-before", fixture: f)
            await task.value
            Self.observeWait("body-join-after", fixture: f)
        }
        #expect(probe.executions == 0 && probe.receipts.isEmpty)
        }
    }
}
