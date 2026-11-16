import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private enum Task05RetryCancelError: Error { case firstChildFailure, unexpectedCall }
actor Task05RetryCancelRunner: ExternalAgentRunner {
    let name = "task05-retry-cancel-unused"
    let isAvailable = true
    func run(task: SubAgentTask) async throws -> String { throw Task05RetryCancelError.unexpectedCall }
}
actor Task05RetryCancelApproval: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(approved: true, confirmed: true,
                         requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

/// Only the remote protocol boundary is controlled. Dispatch, cancellation,
/// transcript writer, TaskCenter mutation and settlement are actual production.
final class Task05RetryCancelProvider: LLMProvider,
    ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "task05-retry-cancel-provider"
    var model = LLMModel(id: "task05-retry-cancel-model", displayName: "owned retry cancel", provider: "task05-retry-cancel-provider")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "owned-task05-retry-cancel-config"
    private let workspace: URL
    private let taskID: String
    private let title: String
    private let lock = NSLock()
    private var childCallsValue = 0
    private var heldValue = false
    private var cancelledValue = false
    private var releasedValue = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(workspace: URL, taskID: String = "task05-cancel-child", title: String = "retry cancellation") {
        self.workspace = workspace
        self.taskID = taskID
        self.title = title
    }
    var childCalls: Int { lock.withLock { childCallsValue } }
    var isHeld: Bool { lock.withLock { heldValue } }
    var sawCancellation: Bool { lock.withLock { cancelledValue } }
    func releaseActualResponse() {
        let pending = lock.withLock {
            releasedValue = true
            let value = continuation
            continuation = nil
            return value
        }
        pending?.resume()
    }
    private func markCancelled() { lock.withLock { cancelledValue = true } }
    private func awaitOwnedRelease() async {
        await withCheckedContinuation { pending in
            let released = lock.withLock {
                heldValue = true
                if releasedValue { return true }
                continuation = pending
                return false
            }
            if released { pending.resume() }
        }
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              tools: [], maxTokens: maxTokens, temperature: temperature)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        if AgentExecutionContext.current?.childToolRuntimeBinding != nil {
            let paragraphs = messages.filter { $0.role == .user }
                .flatMap { $0.content.components(separatedBy: "\n\n") }
            guard paragraphs.contains("task05 cancel original durable instructions") else {
                throw Task05RetryCancelError.unexpectedCall
            }
            let count = lock.withLock { childCallsValue += 1; return childCallsValue }
            if count == 1 { throw Task05RetryCancelError.firstChildFailure }
            guard count == 2 else { throw Task05RetryCancelError.unexpectedCall }
            await withTaskCancellationHandler {
                await awaitOwnedRelease()
            } onCancel: { [self] in markCancelled() }
            // Deliberately late remote success: the production identity and
            // cancellation guards must reject this actual response.
            return LLMResponse(text: "TASK05_LATE_REMOTE_SUCCESS_MUST_NOT_COMMIT", stopReason: "stop", usage: nil)
        }
        if messages.contains(where: { $0.role == .tool || $0.content.contains("\"tool_result\"") }) {
            return LLMResponse(text: "owned parent recorded first failure", stopReason: "stop", usage: nil)
        }
        let payload: [String: Any] = ["tool_calls": [["id": "task05-cancel-orchestrate", "name": OrchestrationToolExecutor.toolName,
            "input": ["input_version": 2, "strategy": "sequential", "tasks": [[
                "id": taskID, "title": title, "instructions": "task05 cancel original durable instructions",
                "agent": "builtin", "required_capabilities": ["tools"],
                "allowed_tool_names": ["file_read"], "allowed_read_roots": [workspace.path]
            ]]]]]]
        return LLMResponse(text: String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self), stopReason: "stop", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw Task05RetryCancelError.unexpectedCall
    }
}

@MainActor
enum TaskCenterRetryProductionFixtureSupport {
    static func makeBridge(root: URL, store: AgentTaskStore, provider: Task05RetryCancelProvider,
                            runner: Task05RetryCancelRunner,
                            expectedAppliedReadiness: [ProviderReadinessPersistenceRecord]? = nil,
                            retainSettingsOwner: ((SettingsCenter) -> Void)? = nil) async throws -> BridgeStore {
        let defaults = try #require(UserDefaults(suiteName: "task05-retry-cancel-\(UUID().uuidString)"))
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        if let expectedAppliedReadiness {
            // Reopening must consume the actual durable Apply receipt. Apply
            // returns only newly applied rows, not a second receipt for it.
            try #require(expectedAppliedReadiness.count == 1)
            try #require(readiness.records == expectedAppliedReadiness)
            let applied = try #require(readiness.records.first)
            #expect(applied.providerID == provider.name && applied.modelID == provider.model.id)
            #expect(applied.isApplied && applied.applyReceiptID?.isEmpty == false)
            #expect(applied.status == .passed && applied.readinessState == .mock)
        } else {
            try #require(readiness.records.isEmpty)
            let checkedAt = Date()
            let lineage = ProviderReadinessLineage.derived(providerID: provider.name,
                                                           modelID: provider.model.id, checkedAt: checkedAt)
            #expect(readiness.upsert([ProviderReadinessPersistenceRecord(
                providerID: provider.name, modelID: provider.model.id,
                status: .passed, readinessState: .mock, checkedAt: checkedAt,
                evidenceID: "task05-retry-cancel-synthetic-readiness", isApplied: false,
                discoveryReceiptID: lineage.discoveryReceiptID, discoveredAt: lineage.discoveredAt
            )]))
            let applied = readiness.applyDiscoveredModels(providerID: provider.name,
                modelIDs: [provider.model.id], appliedAt: checkedAt.addingTimeInterval(1))
            #expect(applied.count == 1 && applied.first?.applyReceiptID?.isEmpty == false)
        }
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            canvasFactory: { _ in preconditionFailure("Task05 must not construct CanvasStore") },
            agentTaskStore: store,
            contextManifestStore: try ContextManifestStore(persistenceURL: root.appendingPathComponent("manifests.json")),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            providerReadinessStore: readiness,
            taskCenterBindingPersistenceURL: root.appendingPathComponent("task-binding.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
            }
        )
        let ownedSessionStore = SessionStore(directory: root.appendingPathComponent("sessions"))
        let ownedBadgeDirectory = root.appendingPathComponent("badges461")
        let ownedBadgeStore = SessionBadgeStore(directory: ownedBadgeDirectory)
        try #require(bridge.chat.attachPersistence(ownedSessionStore, badgeStore: ownedBadgeStore))
        let ownedMCPManager = MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"))
        let ownedSkills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let ownedEnvironment = EnvVarStore(directory: root.appendingPathComponent("env"),
            keychain: KeychainStore(backing: InMemoryKeychainBacking()))
        if let retainSettingsOwner {
            // Only callers exercising the real settings capture opt in and
            // retain this actual same-session owner for their whole operation.
            let settings = SettingsCenter(
                settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
                envStore: ownedEnvironment, memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
                sessionStore: ownedSessionStore, sessionBadgeStore: ownedBadgeStore,
                logManager: LogManager(directory: root.appendingPathComponent("settings-logs")),
                mcpManager: ownedMCPManager, skillStore: ownedSkills, providerReadinessStore: readiness)
            retainSettingsOwner(settings)
        }
        let productionAttachment = bridge.attachProductionServices(
            fileAccessAllowedRoot: root, fileAccessDeniedRoots: [],
            sessionDirectory: root.appendingPathComponent("sessions"),
            mcpManager: ownedMCPManager, skillStore: ownedSkills,
            approvalDelegateOverride: Task05RetryCancelApproval(),
            policyDefaults: ProductionPolicyDefaults(budget: 1_000, deadlineHorizon: 120,
                                                     autonomyLevel: .l3, networkDomains: []),
            enableOrchestration: true, externalRunners: [runner.name: runner],
            // This is the unchanged admission flag from 413. Both injected
            // protocol producers above are local and implement no transport.
            externalNetworkAllowed: true,
            sessionReadSecretStore: ownedEnvironment
        )
        await productionAttachment.value
        // AJ-2's existing-store branch must retain the exact owned authorities.
        // This fixture does not cover Bridge's default created-store branch.
        try #require(bridge.chat.sessionStore === ownedSessionStore)
        let ownedManager = try #require(bridge.chat.sessionManager)
        try #require(ownedManager.store === ownedSessionStore)
        try #require(ownedManager.badgeStore === ownedBadgeStore)
        let expectedSessionDirectory = root.appendingPathComponent("sessions")
        #expect(ownedManager.store.directory.isFileURL && expectedSessionDirectory.isFileURL)
        #expect(ownedManager.store.directory.pathComponents == expectedSessionDirectory.pathComponents)
        #expect(FileManager.default.fileExists(atPath: ownedBadgeDirectory.path))
        bridge.updateApprovalPolicy(.alwaysAsk)
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .auto, approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
        return bridge
    }

}
