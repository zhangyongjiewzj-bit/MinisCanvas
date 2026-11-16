import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class Command1595WorkflowProvider: LLMProvider, @unchecked Sendable {
    let name = "command1595-synthetic-workflow"
    var model = LLMModel(id: "command1595", displayName: "Synthetic workflow", provider: "test")
    private let lock = NSLock()
    private var counts = [0, 0, 0]
    var calls: [Int] { lock.withLock { counts } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { counts[0] += 1 }
        return LLMResponse(text: "合成步骤结果", stopReason: "end_turn", usage: nil)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        lock.withLock { counts[1] += 1 }
        return LLMResponse(text: "合成步骤结果", stopReason: "end_turn", usage: nil)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        lock.withLock { counts[2] += 1 }
        return AsyncThrowingStream { $0.finish() }
    }
}

@Suite("D-COMMAND-09 observed blocker consumption in command discovery")
@MainActor
struct P3AcceptanceM05_CommandAvailabilityConsumerTests {
    @Test("help and commands show one observed blocker without dispatching its target")
    func currentBlockerReachesBothRegistryDiscoveryResults() throws {
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        let center = ComposerCommandAdjudicationCenter()
        #expect(center.installCommandRegistry(registry))
        center.commandAvailabilityReason = { id in
            id == "compact" ? "  当前 Provider 凭据不可用  " : nil
        }
        let (snapshot, facts) = context()

        let specific = try display(
            center: center,
            commandID: "help",
            args: ["command_id": "compact"],
            snapshot: snapshot,
            facts: facts
        )
        #expect(specific.contains("/compact"))
        #expect(specific.contains("当前阻断：当前 Provider 凭据不可用"))

        let helpList = try display(
            center: center, commandID: "help", snapshot: snapshot, facts: facts
        )
        #expect(helpList.contains("/compact ·"))
        #expect(helpList.contains("当前阻断：当前 Provider 凭据不可用"))

        let commands = try display(
            center: center, commandID: "commands", snapshot: snapshot, facts: facts
        )
        #expect(commands.contains("/compact ·"))
        #expect(commands.contains("当前阻断：当前 Provider 凭据不可用"))
        #expect(center.pendingAdjudication == nil)

        // An absent observation is unknown, not a fabricated permission or
        // Provider success verdict.
        center.commandAvailabilityReason = { _ in "  " }
        let unknown = try display(
            center: center,
            commandID: "help",
            args: ["command_id": "compact"],
            snapshot: snapshot,
            facts: facts
        )
        #expect(!unknown.contains("当前阻断："))
        #expect(center.pendingAdjudication == nil)
    }

    @Test("registry-disabled and missing-executor reasons outrank an observed blocker")
    func authoritativeLocalBlockersKeepTheirReason() throws {
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        registry.register(CommandDefinition(
            id: "status", title: "合成状态", category: .session,
            availability: { .disabled(reason: "合成权限阻断") }
        ) { _ in .failure("disabled command must not execute") })
        let center = ComposerCommandAdjudicationCenter()
        #expect(center.installCommandRegistry(registry))
        center.commandAvailabilityReason = { _ in "合成配置阻断" }
        let (snapshot, facts) = context()

        let disabled = try display(
            center: center,
            commandID: "help",
            args: ["command_id": "status"],
            snapshot: snapshot,
            facts: facts
        )
        #expect(disabled.contains("当前阻断：合成权限阻断"))
        #expect(!disabled.contains("合成配置阻断"))

        let noExecutor = try display(
            center: center,
            commandID: "help",
            args: ["command_id": "boundary.set"],
            snapshot: snapshot,
            facts: facts
        )
        #expect(noExecutor.contains("当前阻断：暂不可用，请在设置→智能体调整自主权上限。"))
        #expect(!noExecutor.contains("合成配置阻断"))
        #expect(center.pendingAdjudication == nil)
    }

    private func display(
        center: ComposerCommandAdjudicationCenter,
        commandID: String,
        args: [String: String] = [:],
        snapshot: ComposerSubmissionSnapshot,
        facts: ComposerPolicyFactSource
    ) throws -> String {
        let request = PendingCommandRequest(
            id: UUID(), commandID: commandID, args: args,
            requiresPolicyApproval: false
        )
        #expect(center.evaluate(request: request, snapshot: snapshot, facts: facts) == .execute)
        return try #require(center.projection?.text)
    }

    private func context() -> (ComposerSubmissionSnapshot, ComposerPolicyFactSource) {
        let now = Date()
        let workspaceID = "m05-availability-workspace"
        let revision = "m05-availability-revision"
        let epoch = "m05-availability-epoch"
        return (
            ComposerSubmissionSnapshot(
                mode: .manual, approvalScope: .request, effort: .standard,
                sessionID: "m05-availability-session", turnID: 1,
                taskID: "chat:m05-availability-session:1:attempt",
                workspaceID: workspaceID, createdAt: now,
                policyRevision: revision, grantEpoch: epoch
            ),
            ComposerPolicyFactSource(
                knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
                workspaceID: workspaceID, revision: revision, grantEpoch: epoch,
                leaseID: "m05-availability-lease",
                expiresAt: now.addingTimeInterval(600), revoked: false
            )
        )
    }
}

@Suite("D-COMMAND-06 non-Canvas workflow approval reaches its production runner")
@MainActor
struct P3AcceptanceM05_WorkflowApprovalConsumerTests {
    private struct Fixture {
        let bridge: BridgeStore
        let center: ComposerCommandAdjudicationCenter
        let provider: Command1595WorkflowProvider
        let sessions: SessionStore
    }

    private func fixture() throws -> Fixture {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("command1595-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let defaults = try #require(UserDefaults(suiteName: "command1595-\(UUID().uuidString)"))
        let log = LogManager(directory: root.appendingPathComponent("logs"))
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let workflow = WorkflowStore(storeDirectory: root.appendingPathComponent("workflows"))
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: log, workflowStore: workflow,
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            canvasFactory: { _ in preconditionFailure("workflow approval must not create CanvasStore") },
            agentTaskStore: try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json")),
            contextManifestStore: try ContextManifestStore(persistenceURL: root.appendingPathComponent("contexts.json")),
            memoryStore: memory,
            canvasMutationCoordinatorFactory: { _ in
                preconditionFailure("workflow approval must not create a Canvas coordinator")
            },
            canvasFeatureLane: .phase3NonCanvas
        )
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions", isDirectory: true))
        _ = try sessions.createSession(id: UUID().uuidString, title: "Other synthetic owner", projectID: "other-command1595")
        _ = try sessions.createSession(id: UUID().uuidString, title: "Synthetic workflow owner", projectID: "owner-command1595")
        #expect(bridge.chat.attachPersistence(sessions,
            badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        let backendConfigs = Dictionary(uniqueKeysWithValues: LocalBackendKind.allCases.map {
            ($0, LocalBackendConfig(kind: $0, baseURL: $0.defaultBaseURL, enabled: false))
        })
        let dependencies = CommandDependencies(
            env: EnvVarStore(directory: root.appendingPathComponent("environment"),
                             keychain: KeychainStore(backing: InMemoryKeychainBacking())),
            log: log, backends: LocalBackends(configs: backendConfigs), sessions: sessions,
            memory: memory, workflows: workflow
        )
        let registry = AppCommandCatalog.assembled(bridge: bridge, dependencies: dependencies).registry
        let center = ComposerCommandAdjudicationCenter()
        #expect(ProductionCommandRegistryWiring.bind(registry: registry, chat: bridge.chat, center: center))
        ProductionCommandRegistryWiring.bindWorkflow(bridge: bridge, center: center)
        let provider = Command1595WorkflowProvider()
        bridge.workflowChat.providerOverride = provider
        bridge.chat.configureComposerPolicy(ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: bridge.chat.composerWorkspaceID, revision: "command1595-policy",
            grantEpoch: "command1595-epoch", leaseID: "command1595-lease",
            expiresAt: Date().addingTimeInterval(600), revoked: false
        ))
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
        center.onPendingTerminalResolution = { [weak bridge] resolution in
            let disposition: ComposerCommandPolicyDecision = resolution.outcome == .approvedExecuted ? .execute : .reject
            _ = bridge?.chat.resolvePendingComposerCommand(requestID: resolution.id, disposition: disposition)
        }
        bridge.chat.onComposerCommandPolicy = { [weak bridge, weak center] request, snapshot in
            guard let bridge, let center else { return .reject }
            return center.evaluate(request: request, snapshot: snapshot, facts: bridge.chat.composerPolicyFacts)
        }
        return Fixture(bridge: bridge, center: center, provider: provider, sessions: sessions)
    }

    private func submit(_ f: Fixture) throws -> ComposerCommandReceipt {
        f.bridge.chat.draftText = "/workflow 小说拆解 novel=合成文本"
        f.bridge.chat.submitComposer()
        let receipt = try #require(f.bridge.chat.lastComposerCommandReceipt)
        #expect(receipt.commandID == "workflow" && receipt.disposition == .pending)
        #expect(f.center.pendingAdjudication?.id == receipt.requestID)
        #expect(f.bridge.chat.pendingComposerCommand?.id == receipt.requestID)
        #expect(f.provider.calls == [0, 0, 0] && !f.bridge.workflowChat.isRunning)
        return receipt
    }

    @Test func appRegistryKeepsQuotedWorkflowInputsOnTheOriginalPendingRequest() throws {
        let f = try fixture()
        let rawInputs = "novel=\"第一 章：主角=路人\" style=轻松"
        f.bridge.chat.draftText = "/workflow 小说拆解 \(rawInputs)"
        f.bridge.chat.submitComposer()
        let request = try #require(f.bridge.chat.pendingComposerCommand)
        #expect(request.commandID == "workflow")
        #expect(request.args["template"] == "小说拆解")
        #expect(request.args["args"] == rawInputs)
        #expect(f.center.pendingAdjudication?.id == request.id)
        #expect(f.provider.calls == [0, 0, 0])
    }

    @Test func approvedWorkflowRunsOriginalFourStepTemplateExactlyOnce() async throws {
        let f = try fixture()
        let chat = f.bridge.chat
        let owner = try #require(chat.activeSessionID)
        let before = try #require(f.sessions.loadSession(id: owner.uuidString))
        let receipt = try submit(f)
        #expect(f.center.approveCurrentAdjudication())
        #expect(f.center.lastResolution?.id == receipt.requestID)
        #expect(f.center.lastResolution?.outcome == .approvedExecuted)
        #expect(chat.pendingComposerCommand == nil && f.center.pendingAdjudication == nil)
        for _ in 0..<400 {
            if !f.bridge.workflowChat.isRunning { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!f.bridge.workflowChat.isRunning)
        #expect(f.provider.calls == [4, 0, 0])
        let persisted = try #require(f.sessions.loadSession(id: owner.uuidString))
        #expect(persisted.messages.count > before.messages.count)
        #expect(chat.messages.contains { $0.content.contains("✅ 工作流「小说拆解」执行完成：本次执行 4 步") })
        #expect(!f.center.approveCurrentAdjudication())
    }

    @Test(arguments: ["deny", "expire", "policy-revision", "grant-epoch", "lease-id",
                      "lease-expired", "revoked", "workspace", "switch-session", "owner-consumed",
                      "template-change"])
    func deniedOrStaleWorkflowHasNoRunnerEffect(reason: String) throws {
        let f = try fixture()
        let chat = f.bridge.chat
        let owner = try #require(chat.activeSessionID)
        let before = try #require(f.sessions.loadSession(id: owner.uuidString))
        let receipt = try submit(f)
        switch reason {
        case "deny": f.center.denyCurrentAdjudication()
        case "expire": f.center.expireCurrentAdjudication()
        case "owner-consumed":
            #expect(chat.resolvePendingComposerCommand(requestID: receipt.requestID, disposition: .reject))
            #expect(!f.center.approveCurrentAdjudication())
        case "switch-session":
            let other = try #require(chat.sessions.first(where: { $0.id != owner }))
            chat.switchSession(id: other.id)
            #expect(chat.activeSessionID == other.id)
            #expect(!f.center.approveCurrentAdjudication())
        case "template-change":
            var changed = WorkflowTemplate.manjuNovelBreakdown
            changed.description = "合成模板修订"
            try f.bridge.workflowChat.workflowStore.saveTemplate(changed)
            #expect(!f.center.approveCurrentAdjudication())
        default:
            let old = chat.composerPolicyFacts
            chat.configureComposerPolicy(ComposerPolicyFactSource(
                knownCapabilities: old.knownCapabilities, grantedCapabilities: old.grantedCapabilities,
                allowedWriteRoots: old.allowedWriteRoots,
                workspaceID: reason == "workspace" ? "other-command1595-workspace" : old.workspaceID,
                revision: reason == "policy-revision" ? "changed-command1595-policy" : old.revision,
                grantEpoch: reason == "grant-epoch" ? "changed-command1595-epoch" : old.grantEpoch,
                leaseID: reason == "lease-id" ? "changed-command1595-lease" : old.leaseID,
                expiresAt: reason == "lease-expired" ? Date().addingTimeInterval(-1) : old.expiresAt,
                revoked: reason == "revoked"
            ))
            #expect(!f.center.approveCurrentAdjudication())
        }
        let terminal = try #require(f.center.lastResolution)
        #expect(terminal.id == receipt.requestID && terminal.outcome != .approvedExecuted)
        #expect(f.provider.calls == [0, 0, 0] && !f.bridge.workflowChat.isRunning)
        #expect(f.center.pendingAdjudication == nil && !f.center.approveCurrentAdjudication())
        let persisted = try #require(f.sessions.loadSession(id: owner.uuidString))
        #expect(persisted.messages == before.messages)
    }

    @Test(arguments: ["/workflow 不存在 novel=合成文本", "/workflow 小说拆解"])
    func unavailableTemplateOrInputsCannotBecomeAnApprovalCard(text: String) throws {
        let f = try fixture()
        f.bridge.chat.draftText = text
        f.bridge.chat.submitComposer()
        let receipt = try #require(f.bridge.chat.lastComposerCommandReceipt)
        #expect(receipt.commandID == "workflow" && receipt.disposition == .reject)
        #expect(f.center.pendingAdjudication == nil && f.bridge.chat.pendingComposerCommand == nil)
        #expect(f.center.lastResolution?.id == receipt.requestID)
        #expect(f.provider.calls == [0, 0, 0] && !f.bridge.workflowChat.isRunning)
    }
}
