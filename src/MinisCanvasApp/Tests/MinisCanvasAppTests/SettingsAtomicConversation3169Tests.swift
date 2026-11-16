import Foundation
import CryptoKit
import Testing
import MinisCore
@testable import MinisCanvasApp

private actor Settings3169Approval: ApprovalDelegate {
    private(set) var requests: [ApprovalRequest] = []
    let approved: Bool
    init(approved: Bool = true) { self.approved = approved }
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        return ApprovalDecision(approved: approved, confirmed: approved,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

/// Holds the real BL6 delegate call until the test inspects the persisted
/// settings bytes. Each request must be explicitly released once.
private struct Policy05ApprovalResolution: Sendable {
    let callID: String
    let approved: Bool
}

private actor Policy05HoldingSettingsApproval: ApprovalDelegate {
    private(set) var requests: [ApprovalRequest] = []
    private(set) var resolutions: [Policy05ApprovalResolution] = []
    private var pending: [String: CheckedContinuation<ApprovalDecision, Never>] = [:]

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        return await withCheckedContinuation { pending[request.requestID] = $0 }
    }

    func waitForCount(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(20)
        while requests.count < count && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard requests.count == count else {
            throw NSError(domain: "Policy05HoldingSettingsApproval.missingRequest", code: count)
        }
    }

    func resolve(_ index: Int, approved: Bool) throws {
        guard requests.indices.contains(index),
              let continuation = pending.removeValue(forKey: requests[index].requestID) else {
            throw NSError(domain: "Policy05HoldingSettingsApproval.missingPending", code: index)
        }
        let request = requests[index]
        resolutions.append(Policy05ApprovalResolution(callID: request.callID, approved: approved))
        continuation.resume(returning: ApprovalDecision(
            approved: approved, confirmed: approved,
            requestID: request.requestID, bindingDigest: request.identityDigest
        ))
    }

    var pendingCount: Int { pending.count }
}

private final class Settings3169Provider:
    LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable
{
    let name = "settings3169-offline"
    var model = LLMModel(id: "settings3169-model", displayName: "Settings 2094", provider: "settings3169-offline")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "settings3169-isolated"
    private let lock = NSLock()
    private var requests: [(names: [String], messages: [LLMMessage])] = []
    private let callName: String
    private let callInput: [String: Any]
    private let repeatedTurns: Bool
    private let callIDPrefix: String

    init(name: String, input: [String: Any], repeatedTurns: Bool = false,
         callIDPrefix: String = "settings3169-call") {
        callName = name
        callInput = input
        self.repeatedTurns = repeatedTurns
        self.callIDPrefix = callIDPrefix
    }

    var offeredNames: [String] { lock.withLock { requests.first?.names ?? [] } }
    var returnedToolMessage: String? {
        lock.withLock {
            requests.dropFirst().flatMap(\.messages)
                .first(where: { $0.role == .tool && $0.toolCallID == "\(callIDPrefix)-1" })?.content
        }
    }
    var requestCount: Int { lock.withLock { requests.count } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, tools: [],
                              maxTokens: maxTokens, temperature: temperature)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        let count = lock.withLock {
            requests.append((tools.map(\.name), messages))
            return requests.count
        }
        if count == 1 || (repeatedTurns && count == 3) {
            let data = try JSONSerialization.data(withJSONObject: callInput, options: [.sortedKeys])
            let call = LLMToolCall(
                id: "\(callIDPrefix)-\((count + 1) / 2)", name: callName,
                rawArguments: String(decoding: data, as: UTF8.self), arguments: callInput
            )
            return LLMResponse(text: "", stopReason: "tool_calls", usage: nil, toolCalls: [call])
        }
        return LLMResponse(text: "已处理隔离设置请求。", stopReason: "stop", usage: nil)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("D-SETD actual multi-field conversation consumer 3169", .serialized)
@MainActor
struct SettingsAtomicConversation3169Tests {
    private func makeFixture(
        includeSyntheticSkill: Bool = false,
        canonicalSkillsState: Bool = false
    ) throws -> (SettingsCenter, BridgeStore, URL, SkillsStore, SchedulerTaskStore) {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("setd3169-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let now = Date()
        try #require(readiness.upsert([
            ProviderReadinessPersistenceRecord(
                providerID: "settings3169-offline", modelID: "settings3169-model",
                status: .passed, readinessState: .mock, checkedAt: now,
                evidenceID: "settings3169-synthetic-readiness", isApplied: true,
                discoveryReceiptID: "settings3169-synthetic-discovery", discoveredAt: now,
                applyReceiptID: "provider-readiness-apply:settings3169-synthetic",
                appliedAt: now
            )
        ]))
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("providers"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: sessions, sessionBadgeStore: badges,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: MCPServerManager(
                fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain
            ),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("setd3169-\(UUID().uuidString)")),
            providerReadinessStore: readiness
        )
        let defaults = try #require(UserDefaults(suiteName: "setd3169-\(UUID().uuidString)"))
        let hermes = root.appendingPathComponent("hermes", isDirectory: true)
        if includeSyntheticSkill {
            let skill = hermes.appendingPathComponent("creative/catalog-owned", isDirectory: true)
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            try "---\nname: catalog-owned\ndescription: synthetic\n---\nowned body".write(
                to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
            )
        }
        let skills = SkillsStore(
             appStore: center.skillStore,
            stateFileURL: root.appendingPathComponent(canonicalSkillsState ? "skills-enabled.json" : "skill-state.json")
        )
        let scheduler = SchedulerTaskStore(
            defaults: defaults,
            occurrenceLedgerURL: root.appendingPathComponent("scheduler-occurrences.json")
        )
        let bridge = try BridgeStore(
            taskStorePersistenceURL: root.appendingPathComponent("agent-tasks.json"),
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            settingsCatalogSkillsStore: skills,
            settingsCatalogSchedulerStore: scheduler,
            logManager: LogManager(directory: root.appendingPathComponent("bridge-logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: badges,
            sessionDocumentStore: SessionDocumentStore(directory: sessions.directory),
            sessionStore: sessions, memoryStore: center.memoryStore,
            providerReadinessStore: readiness,
            canvasFeatureLane: .phase3NonCanvas
        )
        // Only the explicit owned local catalog participates in this fixture;
        // app-managed Hermes deployment is a separate original consumer.
        bridge.bindProductionEffectiveSettingsSource { [weak center] in
            center?.bl6EffectiveSettingsSnapshot
        }
        _ = try center.settingsStore.update(\.general.language, to: "zh-Hans").get()
        center.reloadAll()
        return (center, bridge, root, skills, scheduler)
    }

    private func settle(_ chat: ChatStore) async throws {
        try await Task.sleep(for: .milliseconds(100))
        let deadline = Date().addingTimeInterval(20)
        while chat.isStreaming && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!chat.isStreaming)
    }

    private func attach(_ center: SettingsCenter, _ bridge: BridgeStore, root: URL,
                        approval: Settings3169Approval) async {
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval, externalNetworkAllowed: true
        ).value
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request, effort: .standard,
            bypassModeConfirmed: false
        )
    }

    private func twoFieldInput(_ snapshot: BL6EffectiveSettingsSnapshot) throws -> [String: Any] {
        let oldFlag = try #require(snapshot.value(for: "agent.fallback-enabled"))
        guard case let .toggle(flag) = oldFlag else {
            throw NSError(domain: "Settings3169.invalidFixture", code: 1)
        }
        return ["operation": "apply", "expectedRevision": snapshot.catalogRevision,
                "changes": ["general.language": ["kind": "text", "text": "en"],
                            "agent.fallback-enabled": ["kind": "toggle", "toggle": !flag]]]
    }

    private func submit(_ provider: Settings3169Provider, to bridge: BridgeStore) async throws {
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.draftText = "TASK3169 owned two-field settings request"
        bridge.chat.submitComposer()
        try await settle(bridge.chat)
        #expect(provider.requestCount == 2)
        #expect(provider.offeredNames.contains(BL6SettingsToolApproval.toolName))
    }

    @Test func approvedAutomaticApprovalProposalReturnsExplicitRejection() async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer {
            bridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: root)
        }
        let approval = Settings3169Approval()
        await attach(center, bridge, root: root, approval: approval)
        let before = try #require(center.bl6EffectiveSettingsSnapshot)
        let file = center.settingsStore.fileURL
        let beforeBytes = try Data(contentsOf: file)
        let provider = Settings3169Provider(
            name: BL6SettingsToolApproval.toolName,
            input: ["operation": "apply", "expectedRevision": before.catalogRevision,
                    "changes": ["agent.approval-policy": ["kind": "text", "text": "autoApprove"]]],
            callIDPrefix: "approval-policy-auto-approve-refusal"
        )

        try await submit(provider, to: bridge)

        let requests = await approval.requests.filter { $0.toolName == BL6SettingsToolApproval.toolName }
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        let error = try #require(provider.returnedToolMessage)
        #expect(error.hasPrefix("Error executing tool"))
        #expect(error.contains("autoApprove"))
        #expect(try Data(contentsOf: file) == beforeBytes)
        #expect(center.bl6EffectiveSettingsSnapshot == before)
        #expect(try center.settingsStore.bl6ReplayRecord(for: request.requestID).get() == nil)
    }

    @Test func approvedSingleApprovalPolicyProposalPersistsItsOwnRevision() async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer {
            bridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: root)
        }
        let approval = Settings3169Approval()
        await attach(center, bridge, root: root, approval: approval)
        center.onApprovalPolicyChanged = { [weak bridge, weak center] policy in
            bridge?.updateApprovalPolicy(policy, legacyAutomaticCompatibility:
                center?.legacyAutomaticApprovalCompatibilityActive == true)
        }
        let grantStore = bridge.chat.composerGrantStore
        let oldFacts = bridge.chat.composerPolicyFacts
        let before = try #require(center.bl6EffectiveSettingsSnapshot)
        let beforeSettings = center.settingsStore.settings
        let key = BL6SettingsApprovedInput.approvalPolicyKey
        let provider = Settings3169Provider(
            name: BL6SettingsToolApproval.toolName,
            input: ["operation": "apply", "expectedRevision": before.catalogRevision,
                    "changes": [key: ["kind": "text", "text": "riskOnlyAsk"]]],
            callIDPrefix: "approval-policy-risk-only"
        )

        try await submit(provider, to: bridge)

        let requests = await approval.requests.filter { $0.toolName == BL6SettingsToolApproval.toolName }
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        let response = try #require(provider.returnedToolMessage)
        let receipt = try JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(response.utf8))
        #expect(receipt.changedKeys == [key])
        #expect(receipt.previousRevision == before.catalogRevision)
        #expect(receipt.effectiveRevision != before.catalogRevision)
        #expect(center.bl6EffectiveSettingsSnapshot?.catalogRevision == receipt.effectiveRevision)
        var expected = beforeSettings
        expected.agent.approvalPolicy = .riskOnlyAsk
        let reopened = SettingsStore(directory: center.settingsStore.directory)
        #expect(reopened.settings == expected)
        #expect(try reopened.bl6ReplayRecord(for: request.requestID).get()?.receipt == receipt)
        #expect(bridge.chat.composerGrantStore === grantStore)
        #expect(bridge.chat.composerPolicyFacts.revision != oldFacts.revision)
        #expect(bridge.chat.composerPolicyFacts.grantEpoch != oldFacts.grantEpoch)

        let followUp = Settings3169Provider(
            name: BL6SettingsToolApproval.toolName,
            input: ["operation": "apply", "expectedRevision": receipt.effectiveRevision,
                    "changes": [key: ["kind": "text", "text": "alwaysAsk"]]],
            callIDPrefix: "approval-policy-always-ask"
        )
        try await submit(followUp, to: bridge)
        let subsequent = await approval.requests.filter { $0.toolName == BL6SettingsToolApproval.toolName }
        #expect(subsequent.count == 2)
        let freshRequest = try #require(subsequent.last)
        #expect(freshRequest.requestID != request.requestID)
        #expect(freshRequest.identityDigest != request.identityDigest)
        let followUpResponse = try #require(followUp.returnedToolMessage)
        let followUpReceipt = try JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(followUpResponse.utf8))
        #expect(followUpReceipt.previousRevision == receipt.effectiveRevision)
        #expect(center.approvalPolicy == .alwaysAsk)
    }

    private func policy05TerminalInput(_ snapshot: BL6EffectiveSettingsSnapshot,
                                       allowed: [String]) -> [String: Any] {
        let list: ([String]) -> [String: Any] = { ["kind": "list", "list": $0] }
        return ["operation": "apply", "expectedRevision": snapshot.catalogRevision,
                "changes": ["agent.terminal-policy": ["kind": "object", "object": [
                    "automaticAllowCommands": list(allowed),
                    "confirmationCommands": list(["git"]),
                    "userDeniedCommands": list(["rm"])
                ]]]]
    }

    private func policy05ReopenedCenter(at root: URL) -> SettingsCenter {
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        return SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("providers"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            logManager: LogManager(directory: root.appendingPathComponent("reopened-logs")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain)
        )
    }

    private struct Policy05DiskObservation {
        let sha256: String
        let language: String
        let fallback: String
        let allowed: String
        let confirmation: String
        let denied: String
    }

    private func policy05DiskObservation(_ center: SettingsCenter) -> Policy05DiskObservation {
        let destination = center.settingsStore.directory.appendingPathComponent(SettingsStore.fileName)
        let bytes = try? Data(contentsOf: destination)
        // Decode the original on-disk settings bytes, not the live mirror.
        // A missing or invalid file is reported as unknown without replacing
        // the original BL6 receipt decode failure under investigation.
        let stored = bytes.flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
        let policy = stored?.agent.terminalPolicy
        return Policy05DiskObservation(
            sha256: bytes.map { SHA256.hash(data: $0)
                .map { String(format: "%02x", $0) }.joined() } ?? "UNKNOWN",
            language: stored?.general.language ?? "UNKNOWN",
            fallback: stored.map { String($0.agent.fallbackEnabled) } ?? "UNKNOWN",
            allowed: policy.map { String(describing: $0.automaticAllowCommands) } ?? "UNKNOWN",
            confirmation: policy.map { String(describing: $0.confirmationCommands) } ?? "UNKNOWN",
            denied: policy.map { String(describing: $0.userDeniedCommands) } ?? "UNKNOWN"
        )
    }

    private func policy05StageEvidence(
        _ stage: String, callID: String,
        before: Policy05DiskObservation, after: Policy05DiskObservation,
        approval: Policy05HoldingSettingsApproval,
        ledger: ToolExecutionFactLedger?, provider: Settings3169Provider
    ) async -> String {
        let requests = await approval.requests
        let resolutions = await approval.resolutions
        let pendingApprovals = await approval.pendingCount
        let bound = requests.filter { $0.callID == callID }
        let request = bound.first
        let decision = resolutions.first { $0.callID == callID }.map {
            $0.approved ? "delegate_approved" : "delegate_denied"
        } ?? "no_delegate_resolution"
        let toolPending = ledger?.pendingReceipts.filter { $0.toolCallID == callID }.count
        let settled = ledger?.facts.first { $0.toolCallID == callID }?.status.rawValue
        let fields: [String] = [
            "stage=\(stage)", "modelRequests=\(provider.requestCount)",
            "offeredBL6=\(provider.offeredNames.contains(BL6SettingsToolApproval.toolName))",
            "approvalRequests=\(bound.count)", "totalApprovalRequests=\(requests.count)",
            "delegateDecision=\(decision)", "callID=\(request?.callID ?? "none")",
            "inputDigest=\(request?.inputDigest ?? "none")",
            "identityDigest=\(request?.identityDigest ?? "none")",
            "approvalConsumed=UNKNOWN", "pendingApproval=\(pendingApprovals)",
            "pendingToolFacts=\(toolPending.map { String($0) } ?? "UNKNOWN")",
            "settledToolFact=\(settled ?? "UNKNOWN")",
            "beforeSHA=\(before.sha256)", "afterSHA=\(after.sha256)",
            "beforeLanguage=\(before.language)", "afterLanguage=\(after.language)",
            "beforeFallback=\(before.fallback)", "afterFallback=\(after.fallback)",
            "beforeAllowed=\(before.allowed)", "afterAllowed=\(after.allowed)",
            "beforeConfirm=\(before.confirmation)", "afterConfirm=\(after.confirmation)",
            "beforeDenied=\(before.denied)", "afterDenied=\(after.denied)"
        ]
        return fields.joined(separator: ", ")
    }

    private func policy05ApprovedReceipt(_ text: String, stage: String,
                                         evidence: String) throws -> BL6SettingsReceipt {
        do {
            return try JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(text.utf8))
        } catch {
            // This fixture uses only synthetic command names and an in-memory
            // Keychain. Preserve one thrown failure with its original decoder
            // as the underlying error; identify the approved call and bounded,
            // redacted public tool feedback without adding a second issue.
            let feedback = ContentSecretRedactor.redact(String(text.prefix(512)))
            let category = text.hasPrefix("Error executing tool") ? "tool_error"
                : (text.first == "{" ? "malformed_json" : "non_json")
            throw NSError(
                domain: "Policy05ApprovedReceipt.nonReceipt", code: stage == "second" ? 2 : 3,
                userInfo: [NSLocalizedDescriptionKey:
                    "approved \(stage) reply category=\(category): \(feedback); \(evidence)",
                    NSUnderlyingErrorKey: error]
            )
        }
    }

    @Test("the same confirmed bypass identity fails at L1 and passes the production L3 preflight")
    func confirmedBypassProductionPreflightRequiresL3() async throws {
        let now = Date()
        func frozen(_ ceiling: AutonomyLevel) -> ComposerSubmissionSnapshot {
            ComposerSubmissionSnapshot(
                mode: .bypassPermission, approvalScope: .workspace, effort: .standard,
                sessionID: "policy05-preflight-session", turnID: 1,
                taskID: "policy05-preflight-task", attemptID: "policy05-preflight-attempt",
                messageID: "policy05-preflight-message", workspaceID: "policy05-preflight-workspace",
                createdAt: now, policyRevision: "policy05-preflight-revision",
                grantEpoch: "policy05-preflight-epoch", bypassModeConfirmed: true,
                autonomyCeiling: ceiling
            )
        }
        func facts(_ ceiling: AutonomyLevel) -> ComposerPolicyFactSource {
            ComposerPolicyFactSource(
                knownCapabilities: [BL6SettingsToolApproval.toolName],
                grantedCapabilities: [BL6SettingsToolApproval.toolName],
                allowedWriteRoots: [], workspaceID: "policy05-preflight-workspace",
                revision: "policy05-preflight-revision", grantEpoch: "policy05-preflight-epoch",
                leaseID: "policy05-preflight-lease", expiresAt: now.addingTimeInterval(600),
                autonomyCeiling: ceiling
            )
        }
        let l1 = frozen(.l1)
        let l3 = frozen(.l3)
        #expect(l1.sessionID == l3.sessionID && l1.turnID == l3.turnID)
        #expect(l1.taskID == l3.taskID && l1.messageID == l3.messageID)
        #expect(l1.mode == l3.mode && l1.bypassModeConfirmed && l3.bypassModeConfirmed)
        await #expect(throws: ComposerAuthorizationError.modeExceedsAutonomyCeiling(
            required: .l3, maximum: .l1
        )) {
            try await ComposerAuthorizationController(snapshot: l1, facts: facts(.l1))
                .validateSnapshot()
        }
        try await ComposerAuthorizationController(snapshot: l3, facts: facts(.l3))
            .validateSnapshot()
    }

    @Test("Settings acknowledgement waits for an explicit durable L3 save")
    func settingsBypassConfirmationRequiresPersistedUserL3() throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        var selection = center.composerPolicy
        selection.mode = .bypassPermission
        center.composerPolicy = selection
        #expect(center.policyRuntimeDefaults.autonomyLevel == .l2)
        let destination = center.settingsStore.directory.appendingPathComponent(SettingsStore.fileName)
        let before = try Data(contentsOf: destination)
        #expect(!Policy05BypassSettingsConfirmation.setConfirmed(true, in: center))
        #expect(!center.composerPolicy.bypassModeConfirmed)
        #expect(try Data(contentsOf: destination) == before)

        // This is the existing named Save action's SettingsCenter consumer,
        // invoked only after a user has selected L3 in the Settings UI.
        #expect(center.updatePolicyRuntimeDefaults(ProductionPolicyDefaults(autonomyLevel: .l3)))
        #expect(center.policyRuntimeDefaults.autonomyLevel == .l3)
        #expect(SettingsStore(directory: center.settingsStore.directory)
            .settings.agent.policyRuntimeDefaults.autonomyLevel == .l3)
        #expect(!center.composerPolicy.bypassModeConfirmed)
        #expect(Policy05BypassSettingsConfirmation.setConfirmed(true, in: center))
        let reopened = SettingsStore(directory: center.settingsStore.directory)
        #expect(reopened.settings.agent.composerPolicy.mode == .bypassPermission)
        #expect(reopened.settings.agent.composerPolicy.bypassModeConfirmed)
        #expect(reopened.settings.agent.policyRuntimeDefaults.autonomyLevel == .l3)

        let (failingCenter, failingBridge, failingRoot, _, _) = try makeFixture()
        defer {
            failingBridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: failingRoot)
        }
        var failingSelection = failingCenter.composerPolicy
        failingSelection.mode = .bypassPermission
        failingCenter.composerPolicy = failingSelection
        let failingDestination = failingCenter.settingsStore.directory
            .appendingPathComponent(SettingsStore.fileName)
        let preserved = failingRoot.appendingPathComponent("policy05-settings-before.json")
        let preservedBytes = try Data(contentsOf: failingDestination)
        try FileManager.default.moveItem(at: failingDestination, to: preserved)
        try FileManager.default.createDirectory(at: failingDestination,
            withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: failingDestination)
            try? FileManager.default.moveItem(at: preserved, to: failingDestination)
        }
        #expect(!failingCenter.updatePolicyRuntimeDefaults(
            ProductionPolicyDefaults(autonomyLevel: .l3)))
        #expect(failingCenter.policyRuntimeDefaults.autonomyLevel == .l2)
        #expect(!Policy05BypassSettingsConfirmation.setConfirmed(true, in: failingCenter))
        #expect(!failingCenter.composerPolicy.bypassModeConfirmed)
        #expect(try Data(contentsOf: preserved) == preservedBytes)
    }

    @Test("manual mode asks for each model settings write while permission controls stay read-only")
    func confirmedBypassModelSettingsWritesNeedFreshApprovalAndPermissionControlsRemainReadOnly() async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Policy05HoldingSettingsApproval()
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            // The production route admits this in-process scripted provider
            // only under its ordinary provider capability flag. The provider
            // performs no socket or external request (same fixture as above).
            approvalDelegateOverride: approval,
            policyDefaults: ProductionPolicyDefaults(autonomyLevel: .l3),
            externalNetworkAllowed: true
        ).value
        let manual = ComposerPolicySettings(mode: .manual,
            approvalScope: .workspace, effort: .standard, bypassModeConfirmed: false)
        center.composerPolicy = manual
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .workspace, effort: .standard,
            bypassModeConfirmed: false
        )
        #expect(center.settingsStore.settings.agent.composerPolicy == manual)
        #expect(SettingsStore(directory: center.settingsStore.directory).settings.agent.composerPolicy == manual)
        #expect(bridge.chat.composerPolicyFacts.autonomyCeiling == .l3)
        let destination = center.settingsStore.directory.appendingPathComponent(SettingsStore.fileName)
        let original = try #require(center.bl6EffectiveSettingsSnapshot)
        let originalBytes = try Data(contentsOf: destination)
        let originalFallback = center.settingsStore.settings.agent.fallbackEnabled
        let firstBefore = policy05DiskObservation(center)
        let firstLedger = (bridge.chat.agentEngine as? AgentLoopChatEngine)?.toolExecutionFactLedger

        // Denied model call: a pending real delegate decision, no settings
        // effect, no durable replay record, and no reusable grant.
        let denied = Settings3169Provider(name: BL6SettingsToolApproval.toolName,
            input: try twoFieldInput(original),
            callIDPrefix: "policy05-settings-denied")
        bridge.chat.streamingProviderOverride = denied
        bridge.chat.draftText = "synthetic mutable settings change 1"
        bridge.chat.submitComposer()
        let frozenFirstTurn = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        #expect(frozenFirstTurn.mode == .manual)
        #expect(!frozenFirstTurn.bypassModeConfirmed)
        #expect(frozenFirstTurn.autonomyCeiling == bridge.chat.composerPolicyFacts.autonomyCeiling)
        try await ComposerAuthorizationController(
            snapshot: frozenFirstTurn, facts: bridge.chat.composerPolicyFacts
        ).validateSnapshot()
        do { try await approval.waitForCount(1) }
        catch {
            Issue.record("synthetic provider calls=\(denied.requestCount), streaming=\(bridge.chat.isStreaming), turnFrozen=\(bridge.chat.lastComposerSubmissionSnapshot != nil), invalidEffectiveSettings=\(bridge.chat.lastSubmissionBlockedByInvalidSettings)")
            throw error
        }
        #expect(denied.requestCount == 1)
        #expect(denied.offeredNames.contains(BL6SettingsToolApproval.toolName))
        #expect(await approval.pendingCount == 1)
        #expect(try Data(contentsOf: destination) == originalBytes)
        try await approval.resolve(0, approved: false)
        try await settle(bridge.chat)
        #expect(denied.returnedToolMessage?.contains("Error executing tool") == true)
        #expect(center.bl6EffectiveSettingsSnapshot == original)
        #expect(try Data(contentsOf: destination) == originalBytes)
        let deniedRequest = try #require(await approval.requests.first)
        #expect(try center.settingsStore.bl6ReplayRecord(for: deniedRequest.requestID).get() == nil)
        #expect(SettingsStore(directory: center.settingsStore.directory).settings == center.settingsStore.settings)
        let firstEvidence = await policy05StageEvidence(
            "denied", callID: "policy05-settings-denied-1",
            before: firstBefore, after: policy05DiskObservation(center),
            approval: approval, ledger: firstLedger, provider: denied
        )

        let secondBefore = policy05DiskObservation(center)
        let secondLedger = (bridge.chat.agentEngine as? AgentLoopChatEngine)?.toolExecutionFactLedger
        let second = Settings3169Provider(name: BL6SettingsToolApproval.toolName,
            input: try twoFieldInput(original),
            callIDPrefix: "policy05-settings-approved-2")
        bridge.chat.streamingProviderOverride = second
        bridge.chat.draftText = "synthetic mutable settings change 2"
        bridge.chat.submitComposer()
        try await approval.waitForCount(2)
        #expect(second.requestCount == 1)
        #expect(second.offeredNames.contains(BL6SettingsToolApproval.toolName))
        #expect(await approval.pendingCount == 1)
        #expect(try Data(contentsOf: destination) == originalBytes)
        try await approval.resolve(1, approved: true)
        try await settle(bridge.chat)
        let secondEvidence = await policy05StageEvidence(
            "second", callID: "policy05-settings-approved-2-1",
            before: secondBefore, after: policy05DiskObservation(center),
            approval: approval, ledger: secondLedger, provider: second
        )
        let secondText = try #require(second.returnedToolMessage)
        let secondReceipt = try policy05ApprovedReceipt(secondText, stage: "second",
            evidence: "\(firstEvidence); \(secondEvidence)")
        let secondSnapshot = try #require(center.bl6EffectiveSettingsSnapshot)
        #expect(Set(secondReceipt.changedKeys) == ["general.language", "agent.fallback-enabled"])
        #expect(secondReceipt.changedKeys.count == 2)
        #expect(secondSnapshot.catalogRevision == secondReceipt.effectiveRevision)
        #expect(center.settingsStore.settings.general.language == "en")
        #expect(center.settingsStore.settings.agent.fallbackEnabled != originalFallback)
        #expect(SettingsStore(directory: center.settingsStore.directory).settings == center.settingsStore.settings)
        // A new data-store reader proves the second commit is durable without
        // replacing the live SettingsCenter.active owner used by this chat.
        let secondReadback = SettingsStore(directory: center.settingsStore.directory).settings
        #expect(secondReadback.general.language == "en")
        #expect(secondReadback.agent.fallbackEnabled != originalFallback)
        #expect(try center.settingsStore.bl6ReplayRecord(for: secondReceipt.requestID).get()?.receipt == secondReceipt)
        let secondBytes = try Data(contentsOf: destination)
        #expect(secondBytes != originalBytes)

        // The prior approval covered one effect. A new model call in the
        // same workspace must create a distinct pending request.
        let thirdBefore = policy05DiskObservation(center)
        let thirdLedger = (bridge.chat.agentEngine as? AgentLoopChatEngine)?.toolExecutionFactLedger
        let third = Settings3169Provider(name: BL6SettingsToolApproval.toolName,
            input: ["operation": "apply", "expectedRevision": secondSnapshot.catalogRevision,
                    "changes": ["general.language": ["kind": "text", "text": "zh-Hans"],
                                "agent.fallback-enabled": ["kind": "toggle", "toggle": originalFallback]]],
            callIDPrefix: "policy05-settings-approved-3")
        bridge.chat.streamingProviderOverride = third
        bridge.chat.draftText = "synthetic mutable settings change 3"
        bridge.chat.submitComposer()
        try await approval.waitForCount(3)
        #expect(third.requestCount == 1)
        #expect(third.offeredNames.contains(BL6SettingsToolApproval.toolName))
        #expect(await approval.pendingCount == 1)
        #expect(try Data(contentsOf: destination) == secondBytes)
        try await approval.resolve(2, approved: true)
        try await settle(bridge.chat)
        let thirdEvidence = await policy05StageEvidence(
            "third", callID: "policy05-settings-approved-3-1",
            before: thirdBefore, after: policy05DiskObservation(center),
            approval: approval, ledger: thirdLedger, provider: third
        )
        let thirdText = try #require(third.returnedToolMessage)
        let thirdReceipt = try policy05ApprovedReceipt(thirdText, stage: "third",
            evidence: "\(firstEvidence); \(secondEvidence); \(thirdEvidence)")
        let thirdSnapshot = try #require(center.bl6EffectiveSettingsSnapshot)
        #expect(Set(thirdReceipt.changedKeys) == ["general.language", "agent.fallback-enabled"])
        #expect(thirdReceipt.changedKeys.count == 2)
        #expect(thirdSnapshot.catalogRevision == thirdReceipt.effectiveRevision)
        #expect(center.settingsStore.settings.general.language == "zh-Hans")
        #expect(center.settingsStore.settings.agent.fallbackEnabled == originalFallback)
        #expect(TerminalPolicySnapshot(settings: center.settingsStore.settings.agent.terminalPolicy)
            .classify(command: "sudo echo synthetic") == .denied)
        #expect(SettingsStore(directory: center.settingsStore.directory).settings == center.settingsStore.settings)
        let thirdReadback = SettingsStore(directory: center.settingsStore.directory).settings
        #expect(thirdReadback.general.language == "zh-Hans")
        #expect(thirdReadback.agent.fallbackEnabled == originalFallback)
        #expect(try center.settingsStore.bl6ReplayRecord(for: thirdReceipt.requestID).get()?.receipt == thirdReceipt)

        // A model asking to change a permission-related terminal policy
        // still reaches a fresh human request, but the product catalog keeps
        // this control read-only even after that request is approved.
        #expect(BL6SettingsCatalog.deniedApprovedMutationKeys.contains("agent.terminal-policy"))
        let hardBefore = try Data(contentsOf: destination)
        let hardLedger = (bridge.chat.agentEngine as? AgentLoopChatEngine)?.toolExecutionFactLedger
        let hardDenied = Settings3169Provider(name: BL6SettingsToolApproval.toolName,
            input: policy05TerminalInput(thirdSnapshot, allowed: ["echo", "printf"]),
            callIDPrefix: "policy05-settings-hard-denied-4")
        bridge.chat.streamingProviderOverride = hardDenied
        bridge.chat.draftText = "synthetic read-only terminal policy request"
        bridge.chat.submitComposer()
        try await approval.waitForCount(4)
        #expect(hardDenied.requestCount == 1)
        #expect(hardDenied.offeredNames.contains(BL6SettingsToolApproval.toolName))
        #expect(await approval.pendingCount == 1)
        #expect(try Data(contentsOf: destination) == hardBefore)
        try await approval.resolve(3, approved: true)
        try await settle(bridge.chat)
        let hardText = try #require(hardDenied.returnedToolMessage)
        #expect(hardText.hasPrefix("Error executing tool"))
        #expect(try Data(contentsOf: destination) == hardBefore)
        #expect(center.bl6EffectiveSettingsSnapshot == thirdSnapshot)
        let hardRequest = try #require(await approval.requests.last)
        #expect(try center.settingsStore.bl6ReplayRecord(for: hardRequest.requestID).get() == nil)
        #expect(hardLedger?.facts.first(where: {
            $0.toolCallID == "policy05-settings-hard-denied-4-1"
        })?.status == .failed)
        #expect(hardLedger?.pendingReceipts.contains(where: {
            $0.toolCallID == "policy05-settings-hard-denied-4-1"
        }) == false)

        let requests = await approval.requests
        #expect(requests.count == 4 && Set(requests.map(\.callID)).count == 4)
        #expect(requests.map(\.callID) == ["policy05-settings-denied-1",
            "policy05-settings-approved-2-1", "policy05-settings-approved-3-1",
            "policy05-settings-hard-denied-4-1"])
        let requestMetadata = requests.enumerated().map { ordinal, request in
            "ordinal=\(ordinal + 1),callID=\(request.callID),tool=\(request.toolName)," +
            "risk=\(request.riskLevel),required=\(request.requiresApproval)," +
            "second=\(request.requiresSecondConfirmation)," +
            "hasInputDigest=\(request.inputDigest != nil)," +
            "hasIdentityDigest=\(request.identityDigest != nil)"
        }.joined(separator: "; ")
        // A settings write remains high risk and asks anew on every call, but
        // the manual-mode contract requires only one approval each time.
        // Log only synthetic request metadata.
        #expect(requests.allSatisfy { $0.toolName == BL6SettingsToolApproval.toolName &&
            $0.requiresApproval && !$0.requiresSecondConfirmation &&
            $0.inputDigest != nil && $0.identityDigest != nil },
            "synthetic approval metadata: \(requestMetadata)")
        // Denied and retried calls intentionally have identical payloads;
        // their distinct call/binding identities still cannot share consent.
        #expect(Set(requests.compactMap(\.inputDigest)).count == 3)
        #expect(Set(requests.compactMap(\.identityDigest)).count == 4)
        #expect(await approval.pendingCount == 0)
        #expect(deniedRequest.requestID != secondReceipt.requestID &&
            secondReceipt.requestID != thirdReceipt.requestID &&
            thirdReceipt.requestID != hardRequest.requestID)

        // A full SettingsCenter restart changes the process-wide active owner,
        // so perform it only after the last model call and assert disk readback.
        let reopened = policy05ReopenedCenter(at: root)
        #expect(reopened.bl6EffectiveSettingsSnapshot?.value(for: "general.language")
            == thirdSnapshot.value(for: "general.language"))
        #expect(reopened.bl6EffectiveSettingsSnapshot?.value(for: "agent.fallback-enabled")
            == thirdSnapshot.value(for: "agent.fallback-enabled"))
        #expect(reopened.settingsStore.settings == center.settingsStore.settings)
    }

    @Test("confirmed bypass commits mutable settings without a card and rejects read-only permissions")
    func confirmedBypassWritesSettingsWithoutCardAndRejectsReadOnlyPermissions() async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Settings3169Approval(approved: false)
        #expect(center.updatePolicyRuntimeDefaults(ProductionPolicyDefaults(autonomyLevel: .l3)))
        var selection = center.composerPolicy
        selection.mode = .bypassPermission
        center.composerPolicy = selection
        try #require(Policy05BypassSettingsConfirmation.setConfirmed(true, in: center))
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: approval,
            policyDefaults: ProductionPolicyDefaults(autonomyLevel: .l3),
            externalNetworkAllowed: true
        ).value
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .bypassPermission, approvalScope: .request, effort: .standard,
            bypassModeConfirmed: true
        )
        let before = try #require(center.bl6EffectiveSettingsSnapshot)
        let mutable = Settings3169Provider(name: BL6SettingsToolApproval.toolName,
            input: try twoFieldInput(before), callIDPrefix: "policy05-bypass-mutable")
        try await submit(mutable, to: bridge)
        #expect(bridge.chat.lastComposerSubmissionSnapshot?.bypassModeConfirmed == true)
        #expect(await approval.requests.isEmpty)
        let response = try #require(mutable.returnedToolMessage)
        let receipt = try JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(response.utf8))
        #expect(Set(receipt.changedKeys) == ["general.language", "agent.fallback-enabled"])
        #expect(receipt.previousRevision == before.catalogRevision)
        let after = try #require(center.bl6EffectiveSettingsSnapshot)
        #expect(after.catalogRevision == receipt.effectiveRevision)
        let reopened = SettingsStore(directory: center.settingsStore.directory)
        #expect(reopened.settings == center.settingsStore.settings)
        #expect(try reopened.bl6ReplayRecord(for: receipt.requestID).get()?.receipt == receipt)
        let destination = reopened.directory.appendingPathComponent(SettingsStore.fileName)
        let appliedBytes = try Data(contentsOf: destination)

        let readOnly = Settings3169Provider(name: BL6SettingsToolApproval.toolName,
            input: policy05TerminalInput(after, allowed: ["echo", "printf"]),
            callIDPrefix: "policy05-bypass-read-only")
        try await submit(readOnly, to: bridge)
        #expect(await approval.requests.isEmpty)
        #expect(readOnly.returnedToolMessage?.hasPrefix("Error executing tool") == true)
        #expect(center.bl6EffectiveSettingsSnapshot == after)
        #expect(try Data(contentsOf: destination) == appliedBytes)
    }

    @Test("one actual approved Provider call commits both fields; receipt Undo restores both and stored exact retry is inert")
    func twoFieldApplyUndoAndStoredReplay() async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Settings3169Approval()
        await attach(center, bridge, root: root, approval: approval)
        let before = try #require(center.bl6EffectiveSettingsSnapshot)
        let beforeSettings = center.settingsStore.settings
        let provider = Settings3169Provider(name: BL6SettingsToolApproval.toolName,
            input: try twoFieldInput(before), callIDPrefix: "two-field-apply")
        try await submit(provider, to: bridge)
        let text = try #require(provider.returnedToolMessage)
        let receipt = try JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(text.utf8))
        #expect(Set(receipt.changedKeys) == ["general.language", "agent.fallback-enabled"])
        #expect(receipt.changedKeys.count == 2)
        #expect(receipt.previousRevision == before.catalogRevision)
        #expect(receipt.effectiveRevision != before.catalogRevision)
        #expect(receipt.rollbackValues.isEmpty)
        let applied = try #require(center.bl6EffectiveSettingsSnapshot)
        #expect(applied.catalogRevision == receipt.effectiveRevision)
        #expect(applied.value(for: "general.language") == .text("en"))
        #expect(applied.value(for: "agent.fallback-enabled") != before.value(for: "agent.fallback-enabled"))
        let reopened = SettingsStore(directory: center.settingsStore.directory)
        #expect(reopened.settings == center.settingsStore.settings)
        let record = try #require(try reopened.bl6ReplayRecord(for: receipt.requestID).get())
        #expect(record.receipt == receipt)
        #expect(record.rollbackValues == before.values)
        let appliedBytes = try Data(contentsOf: reopened.directory.appendingPathComponent(SettingsStore.fileName))
        // Actual canonical Store exact replay is below the live approval wrapper;
        // this does not claim that a consumed/revoked approval can be reused.
        #expect(try reopened.commitBL6Replay(expectedSettings: reopened.settings,
            candidate: reopened.settings, record: record).get() == receipt)
        #expect(try Data(contentsOf: reopened.directory.appendingPathComponent(SettingsStore.fileName)) == appliedBytes)

        let undo = Settings3169Provider(name: BL6SettingsToolApproval.toolName,
            input: ["operation": "rollback", "expectedRevision": applied.catalogRevision,
                    "changes": [String: Any](), "undoReceiptID": receipt.receiptID],
            callIDPrefix: "two-field-undo")
        try await submit(undo, to: bridge)
        let undoText = try #require(undo.returnedToolMessage)
        let undoReceipt = try JSONDecoder().decode(BL6SettingsReceipt.self, from: Data(undoText.utf8))
        #expect(undoReceipt.operation == .rollback)
        #expect(Set(undoReceipt.changedKeys) == Set(receipt.changedKeys))
        #expect(undoReceipt.changedKeys.count == 2)
        #expect(center.settingsStore.settings == beforeSettings)
        #expect(center.bl6EffectiveSettingsSnapshot?.values == before.values)
        let afterUndo = SettingsStore(directory: center.settingsStore.directory)
        #expect(afterUndo.settings == beforeSettings)
        let undoRecord = try #require(try afterUndo.bl6ReplayRecord(for: undoReceipt.requestID).get())
        #expect(undoRecord.receipt == undoReceipt)
        let undoBytes = try Data(contentsOf: afterUndo.directory.appendingPathComponent(SettingsStore.fileName))
        #expect(try afterUndo.commitBL6Replay(expectedSettings: afterUndo.settings,
            candidate: afterUndo.settings, record: record).get() == receipt)
        #expect(try afterUndo.commitBL6Replay(expectedSettings: afterUndo.settings,
            candidate: afterUndo.settings, record: undoRecord).get() == undoReceipt)
        #expect(afterUndo.settings == beforeSettings)
        #expect(try Data(contentsOf: afterUndo.directory.appendingPathComponent(SettingsStore.fileName)) == undoBytes)
        let asked = await approval.requests.filter { $0.toolName == BL6SettingsToolApproval.toolName }
        #expect(asked.count == 2)
        #expect(Set(asked.map(\.callID)).count == 2)
    }

    @Test("denied live approval for a two-field Provider proposal persists neither field nor replay metadata")
    func deniedTwoFieldProposalIsZeroWrite() async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Settings3169Approval(approved: false)
        await attach(center, bridge, root: root, approval: approval)
        let before = try #require(center.bl6EffectiveSettingsSnapshot)
        let beforeSettings = center.settingsStore.settings
        let bytes = try Data(contentsOf: center.settingsStore.directory.appendingPathComponent(SettingsStore.fileName))
        let provider = Settings3169Provider(name: BL6SettingsToolApproval.toolName,
            input: try twoFieldInput(before), callIDPrefix: "two-field-denied")
        try await submit(provider, to: bridge)
        #expect(provider.returnedToolMessage?.contains("Error executing tool") == true)
        #expect(center.settingsStore.settings == beforeSettings)
        #expect(center.bl6EffectiveSettingsSnapshot == before)
        #expect(try Data(contentsOf: center.settingsStore.directory.appendingPathComponent(SettingsStore.fileName)) == bytes)
        #expect(SettingsStore(directory: center.settingsStore.directory).settings == beforeSettings)
        #expect(await approval.requests.filter { $0.toolName == BL6SettingsToolApproval.toolName }.count == 1)
    }

    @Test("real atomic settings-file failure after two-field approval publishes neither field nor terminal receipt")
    func approvedTwoFieldPersistenceFailureKeepsWholeBefore() async throws {
        let (center, bridge, root, _, _) = try makeFixture()
        defer { bridge.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let approval = Settings3169Approval()
        await attach(center, bridge, root: root, approval: approval)
        let before = try #require(center.bl6EffectiveSettingsSnapshot)
        let beforeSettings = center.settingsStore.settings
        let destination = center.settingsStore.directory.appendingPathComponent(SettingsStore.fileName)
        let preserved = root.appendingPathComponent("owned-settings-before.json")
        let bytes = try Data(contentsOf: destination)
        try FileManager.default.moveItem(at: destination, to: preserved)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        defer {
            if FileManager.default.fileExists(atPath: preserved.path) {
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.moveItem(at: preserved, to: destination)
            }
        }
        let provider = Settings3169Provider(name: BL6SettingsToolApproval.toolName,
            input: try twoFieldInput(before), callIDPrefix: "two-field-write-failure")
        try await submit(provider, to: bridge)
        #expect(provider.returnedToolMessage?.contains("Error executing tool") == true)
        #expect(center.settingsStore.lastPersistenceError == .writeFailed)
        #expect(center.settingsStore.settings == beforeSettings)
        #expect(center.bl6EffectiveSettingsSnapshot == before)
        #expect(try Data(contentsOf: preserved) == bytes)
        let asked = await approval.requests.filter { $0.toolName == BL6SettingsToolApproval.toolName }
        #expect(asked.count == 1)
        let request = try #require(asked.first)
        #expect(try center.settingsStore.bl6ReplayRecord(for: request.requestID).get() == nil)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: preserved, to: destination)
        let reopened = SettingsStore(directory: center.settingsStore.directory)
        #expect(reopened.settings == beforeSettings)
        #expect(try Data(contentsOf: reopened.directory.appendingPathComponent(SettingsStore.fileName)) == bytes)
        #expect(try reopened.bl6ReplayRecord(for: request.requestID).get() == nil)
    }
}
