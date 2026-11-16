import Foundation
import Darwin
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class Command1887Provider: LLMProvider, @unchecked Sendable {
    let name: String
    var model = LLMModel(id: "command1887", displayName: "Synthetic command probe", provider: "test")
    private let lock = NSLock()
    private var sent = 0
    private var streamed = 0
    private var invocations: [WorkflowProviderInvocation?] = []

    init(name: String) { self.name = name }

    var sendCount: Int { lock.withLock { sent } }
    var streamCount: Int { lock.withLock { streamed } }
    var workflowInvocations: [WorkflowProviderInvocation?] { lock.withLock { invocations } }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        let invocation = WorkflowProviderInvocationContext.current
        lock.withLock {
            sent += 1
            invocations.append(invocation)
        }
        return LLMResponse(text: "合成步骤结果", stopReason: "end_turn", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages, systemPrompt: systemPrompt,
            maxTokens: maxTokens, temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        lock.withLock { streamed += 1 }
        return AsyncThrowingStream { $0.finish() }
    }
}

@Suite("D-COMMAND-06/08 real workflow occurrence and disabled submissions")
@MainActor
struct DCommand0608ProductionConsumerTests {
    private struct Fixture {
        let bridge: BridgeStore
        let center: ComposerCommandAdjudicationCenter
        let sessions: SessionStore
        let root: URL
        let runnerProvider: Command1887Provider
        let ordinaryProvider: Command1887Provider
        let lifetime: FixtureLifetime
    }

    @MainActor
    private final class FixtureLifetime {
        let profile: RuntimeIsolationProfile
        private(set) var suites: [String] = []
        private(set) var completions: [UUID: WorkflowChatRunCompletion] = [:]
        private(set) var requiredCompletionMissing = false
        init(profile: RuntimeIsolationProfile) { self.profile = profile }
        func makeDefaults(_ label: String) throws -> UserDefaults {
            let suite = "COMMAND06-" + label + "-" + UUID().uuidString
            try #require(UserDefaults.standard.persistentDomain(forName: suite) == nil)
            suites.append(suite)
            return try #require(UserDefaults(suiteName: suite))
        }
        @discardableResult
        func captureCurrentRun(_ controller: WorkflowChatController) -> WorkflowChatRunCompletion? {
            guard let completion = controller.currentRunCompletion() else { return nil }
            completions[completion.runID] = completion
            return completion
        }
        func requireCurrentRun(_ controller: WorkflowChatController) throws {
            let completion = captureCurrentRun(controller)
            if completion == nil { requiredCompletionMissing = true }
            try #require(completion != nil)
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

    /// Every business return/throw reaches real workflow Task completion before
    /// suite/root removal. A hung join retains the fixture for the outer runner.
    private func withFixture(_ body: @MainActor (Fixture) async throws -> Void) async throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "COMMAND06-workflow1887", canvasRuntimeState: .disabled)
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
        // A synchronous rejection regression may unexpectedly launch a workflow.
        // Capture before cancel clears the controller's handle, with no intervening await.
        if let active {
            lifetime.captureCurrentRun(active.bridge.workflowChat)
            active.center.denyCurrentAdjudication()
            active.bridge.approvalCenter.dismissPending()
            active.bridge.workflowChat.cancel()
        }
        for id in lifetime.completions.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            if let completion = lifetime.completions[id] { await completion.wait() }
        }
        let cleanup: Result<Void, Error>
        do {
            // Missing a required launch handle is a failed ownership qualification,
            // not zero completed Tasks. Retain both suites and root in that case.
            try #require(!lifetime.requiredCompletionMissing)
            try lifetime.clearSuites()
            B1ARCHOriginalFixtureSupport.cleanupProfile(profile)
            var observed = stat(); errno = 0
            let status = lstat(profile.rootDirectory.path, &observed)
            let code = errno
            guard status == -1, code == ENOENT else {
                throw RootNotRemoved(path: profile.rootDirectory.path, status: status, code: code)
            }
            print("COMMAND06_workflow1887_CLEANUP joined=\(lifetime.completions.count) exactRootENOENT=true")
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
        let root = lifetime.profile.rootDirectory
        let defaults = try lifetime.makeDefaults("workflow1887")
        let environment = EnvVarStore(directory: root.appendingPathComponent("environment"),
            keychain: KeychainStore(backing: InMemoryKeychainBacking()),
            privacyStore: EnvVarPrivacyStore(defaults: defaults))
        let ownedBadges = SessionBadgeStore(directory: root.appendingPathComponent("bridge-badges"))
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let log = LogManager(directory: root.appendingPathComponent("logs"))
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let workflow = WorkflowStore(storeDirectory: root.appendingPathComponent("workflows"))
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: log, workflowStore: workflow, sessionBadgeStore: ownedBadges,
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            canvasFactory: { _ in preconditionFailure("Disabled Canvas must not construct a runtime") },
            agentTaskStore: try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json")),
            contextManifestStore: try ContextManifestStore(persistenceURL: root.appendingPathComponent("contexts.json")),
            memoryStore: memory, commandEnvStore: environment,
            canvasMutationCoordinatorFactory: { _ in
                preconditionFailure("Disabled Canvas must not construct a coordinator")
            },
            providerReadinessStore: readiness,
            taskCenterBindingPersistenceURL: root.appendingPathComponent("bindings.json"),
            canvasFeatureLane: .phase3NonCanvas
        )
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions", isDirectory: true))
        _ = try sessions.createSession(
            id: UUID().uuidString, title: "Synthetic command owner", projectID: "project-command1887"
        )
        #expect(bridge.chat.attachPersistence(
            sessions, badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        ))
        try #require(bridge.chat.draftStore == nil && bridge.chat.usageStore == nil)
        let backendConfigs = Dictionary(uniqueKeysWithValues: LocalBackendKind.allCases.map {
            ($0, LocalBackendConfig(kind: $0, baseURL: $0.defaultBaseURL, enabled: false))
        })
        let dependencies = CommandDependencies(
            env: environment,
            log: log, backends: LocalBackends(configs: backendConfigs), sessions: sessions,
            memory: memory, workflows: workflow
        )
        let registry = AppCommandCatalog.assembled(bridge: bridge, dependencies: dependencies).registry
        let center = ComposerCommandAdjudicationCenter()
        #expect(ProductionCommandRegistryWiring.bind(registry: registry, chat: bridge.chat, center: center))
        ProductionCommandRegistryWiring.bindWorkflow(bridge: bridge, center: center)
        let runnerProvider = Command1887Provider(name: "workflow-runner-1887")
        let ordinaryProvider = Command1887Provider(name: "ordinary-chat-1887")
        bridge.workflowChat.providerOverride = runnerProvider
        bridge.chat.streamingProviderOverride = ordinaryProvider
        bridge.chat.compactionProviderOverride = ordinaryProvider
        bridge.chat.configureComposerPolicy(ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: bridge.chat.composerWorkspaceID, revision: "command1887-policy",
            grantEpoch: "command1887-epoch", leaseID: "command1887-lease",
            expiresAt: Date().addingTimeInterval(600), revoked: false, autonomyCeiling: .l3
        ))
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request, effort: .standard,
            bypassModeConfirmed: false
        )
        center.onPendingTerminalResolution = { [weak bridge] resolution in
            let disposition: ComposerCommandPolicyDecision = resolution.outcome == .approvedExecuted
                ? .execute : .reject
            _ = bridge?.chat.resolvePendingComposerCommand(
                requestID: resolution.id, disposition: disposition
            )
        }
        bridge.chat.onComposerCommandPolicy = { [weak bridge, weak center] request, snapshot in
            guard let bridge, let center else { return .reject }
            return center.evaluate(
                request: request, snapshot: snapshot, facts: bridge.chat.composerPolicyFacts
            )
        }
        return Fixture(
            bridge: bridge, center: center, sessions: sessions, root: root,
            runnerProvider: runnerProvider, ordinaryProvider: ordinaryProvider, lifetime: lifetime
        )
    }

    private func submitWorkflow(_ f: Fixture) throws -> ComposerCommandReceipt {
        f.bridge.chat.draftText = "/workflow 小说拆解 novel=合成文本"
        f.bridge.chat.submitComposer()
        let receipt = try #require(f.bridge.chat.lastComposerCommandReceipt)
        #expect(receipt.commandID == "workflow" && receipt.disposition == .pending)
        #expect(f.center.pendingAdjudication?.id == receipt.requestID)
        #expect(f.bridge.chat.pendingComposerCommand?.id == receipt.requestID)
        #expect(f.runnerProvider.sendCount == 0 && f.ordinaryProvider.sendCount == 0)
        return receipt
    }

    private func reopenedReceipt(_ f: Fixture) throws -> ComposerCommandReceipt? {
        let defaults = try f.lifetime.makeDefaults("workflow1887-reopen")
        let chat = ChatStore(
            providerReadinessStore: ProviderReadinessStore(directory: f.root.appendingPathComponent("reopen-readiness")),
            preferencesDefaults: defaults,
            logManager: LogManager(directory: f.root.appendingPathComponent("reopen-logs"))
        )
        #expect(chat.attachPersistence(
            f.sessions,
            badgeStore: SessionBadgeStore(directory: f.root.appendingPathComponent("reopen-badges"))
        ))
        #expect(chat.pendingComposerCommand == nil)
        return chat.lastComposerCommandReceipt
    }

    @Test func keyboardBypassStartsExactlyOneCanonicalWorkflowOccurrence() async throws {
        try await withFixture { f in
        let chat = f.bridge.chat
        chat.composerPolicySelection.mode = .bypassPermission
        #expect(chat.confirmComposerBypass(for: chat.activeSessionID))
        chat.draftText = "/workflow 小说拆解 novel=合成文本"
        chat.submitComposerFromKeyboard()
        let receipt = try #require(chat.lastComposerCommandReceipt)
        #expect(receipt.disposition == .execute)
        #expect(chat.pendingComposerCommand == nil && f.center.pendingAdjudication == nil)
        #expect(f.center.projection?.id == receipt.requestID)
        try f.lifetime.requireCurrentRun(f.bridge.workflowChat)
        for _ in 0..<400 {
            if !f.bridge.workflowChat.isRunning { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!f.bridge.workflowChat.isRunning)
        let calls = f.runnerProvider.workflowInvocations
        #expect(calls.count == 4 && calls.allSatisfy { $0?.occurrenceID == receipt.requestID })
        #expect(f.ordinaryProvider.sendCount == 0 && f.ordinaryProvider.streamCount == 0)
        }
    }

    @Test func approvedWorkflowHasOneOccurrenceAndRunnerOnlyProviderCallsAfterReload() async throws {
        try await withFixture { f in
        let chat = f.bridge.chat
        let owner = try #require(chat.activeSessionID)
        let before = try #require(f.sessions.loadSession(id: owner.uuidString))
        let receipt = try submitWorkflow(f)
        // A pending approval has no terminal result to project yet. The
        // visible outcome is asserted below, after the user approval.
        #expect(f.center.projection == nil)
        #expect(f.center.approveCurrentAdjudication())
        try f.lifetime.requireCurrentRun(f.bridge.workflowChat)
        #expect(f.center.lastResolution?.id == receipt.requestID)
        #expect(f.center.lastResolution?.outcome == .approvedExecuted)
        for _ in 0..<400 {
            if !f.bridge.workflowChat.isRunning { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!f.bridge.workflowChat.isRunning)
        let calls = f.runnerProvider.workflowInvocations
        #expect(calls.count == 4)
        #expect(calls.allSatisfy { $0?.occurrenceID == receipt.requestID })
        #expect(Set(calls.compactMap { $0?.runID }).count == 1)
        #expect(f.runnerProvider.sendCount == 4 && f.runnerProvider.streamCount == 0)
        #expect(f.ordinaryProvider.sendCount == 0 && f.ordinaryProvider.streamCount == 0)
        #expect(chat.messages.allSatisfy { $0.role != .user })
        #expect(f.center.projection?.id == receipt.requestID && f.center.pendingAdjudication == nil)
        #expect(chat.lastComposerCommandReceipt == receipt && chat.pendingComposerCommand == nil)
        let persisted = try #require(f.sessions.loadSession(id: owner.uuidString))
        #expect(persisted.messages.count > before.messages.count)
        #expect(try reopenedReceipt(f) == receipt)
        }
    }

    @Test(arguments: ["deny", "expire"])
    func deniedOrExpiredWorkflowHasNoRunnerCallAndKeepsOneReceipt(reason: String) async throws {
        try await withFixture { f in
        let before = f.bridge.chat.messages
        let receipt = try submitWorkflow(f)
        if reason == "deny" { f.center.denyCurrentAdjudication() }
        else { f.center.expireCurrentAdjudication() }
        #expect(f.center.lastResolution?.id == receipt.requestID)
        if reason == "deny" {
            #expect(f.center.lastResolution?.outcome == .deniedByUser)
        } else {
            #expect(f.center.lastResolution?.outcome == .expiredUnanswered)
        }
        #expect(f.center.projection?.id == receipt.requestID)
        #expect(f.center.pendingAdjudication == nil && f.bridge.chat.pendingComposerCommand == nil)
        #expect(f.bridge.chat.lastComposerCommandReceipt == receipt)
        #expect(f.bridge.chat.messages == before)
        #expect(f.runnerProvider.sendCount == 0 && f.ordinaryProvider.sendCount == 0)
        #expect(try reopenedReceipt(f) == receipt)
        }
    }

    @Test(arguments: ["policy-change", "switch-session", "lease-expired", "revoked",
                      "lease-replaced", "epoch-replaced", "owner-consumed"])
    func staleWorkflowApprovalCannotStartRunnerOrWriteHistory(reason: String) async throws {
        try await withFixture { f in
        let chat = f.bridge.chat
        let owner = try #require(chat.activeSessionID)
        let before = try #require(f.sessions.loadSession(id: owner.uuidString))
        let receipt = try submitWorkflow(f)
        switch reason {
        case "switch-session":
            chat.newSession()
            #expect(chat.activeSessionID != owner)
        case "owner-consumed":
            #expect(chat.resolvePendingComposerCommand(requestID: receipt.requestID,
                                                       disposition: .reject))
        default:
            let old = chat.composerPolicyFacts
            chat.configureComposerPolicy(ComposerPolicyFactSource(
                knownCapabilities: old.knownCapabilities,
                grantedCapabilities: old.grantedCapabilities,
                allowedWriteRoots: old.allowedWriteRoots,
                workspaceID: old.workspaceID,
                revision: reason == "policy-change" ? "changed-command1887-policy" : old.revision,
                grantEpoch: reason == "epoch-replaced" ? "changed-command1887-epoch" : old.grantEpoch,
                leaseID: reason == "lease-replaced" ? "changed-command1887-lease" : old.leaseID,
                expiresAt: reason == "lease-expired" ? Date().addingTimeInterval(-1) : old.expiresAt,
                revoked: reason == "revoked"
            ))
        }
        #expect(!f.center.approveCurrentAdjudication())
        f.lifetime.captureCurrentRun(f.bridge.workflowChat)
        #expect(f.center.lastResolution?.id == receipt.requestID)
        #expect(f.center.lastResolution?.outcome != .approvedExecuted)
        #expect(!f.bridge.workflowChat.isRunning)
        #expect(f.runnerProvider.sendCount == 0 && f.runnerProvider.streamCount == 0)
        #expect(f.ordinaryProvider.sendCount == 0 && f.ordinaryProvider.streamCount == 0)
        #expect(f.bridge.canvasIfAvailable == nil && f.bridge.composerCanvasDispatchCount == 0)
        let after = try #require(f.sessions.loadSession(id: owner.uuidString))
        #expect(after.messages == before.messages)
        #expect(chat.lastComposerCommandReceipt == receipt)
        #expect(!f.center.approveCurrentAdjudication())
        f.lifetime.captureCurrentRun(f.bridge.workflowChat)
        }
    }

    @Test(arguments: ["/boundary.set strict", "/canvas.run"], [false, true])
    func unsupportedCommandsRejectBeforeApprovalOrSideEffect(input: String, bypass: Bool) async throws {
        try await withFixture { f in
        let before = f.bridge.chat.messages
        if bypass {
            f.bridge.chat.composerPolicySelection.mode = .bypassPermission
            #expect(f.bridge.chat.confirmComposerBypass(for: f.bridge.chat.activeSessionID))
        }
        f.bridge.chat.draftText = input
        f.bridge.chat.submitComposerFromKeyboard()
        #expect(f.bridge.chat.pendingComposerCommand == nil && f.center.pendingAdjudication == nil)
        #expect(f.bridge.chat.lastComposerCommandReceipt?.disposition != .pending)
        #expect(f.center.projection?.text != nil || f.bridge.chat.composerCommandValidationFailure?.message != nil)
        if input.hasPrefix("/boundary.set") {
            #expect(f.center.projection?.text.contains("设置→智能体") == true)
        }
        #expect(f.bridge.chat.messages == before)
        #expect(f.runnerProvider.sendCount == 0 && f.ordinaryProvider.sendCount == 0)
        #expect(f.bridge.canvasIfAvailable == nil && f.bridge.composerCanvasDispatchCount == 0)
        }
    }
}
