import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private actor Policy599Approval: ApprovalDelegate {
    private var approvalsLeft: Int
    private(set) var requests: [ApprovalRequest] = []
    init(approvals: Int) { approvalsLeft = approvals }
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        let allow = approvalsLeft > 0
        if allow { approvalsLeft -= 1 }
        return ApprovalDecision(approved: allow, reason: allow ? nil : "synthetic user denial",
            confirmed: allow, requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

/// Fixed local model input only. Its final answer makes no execution claim.
private final class Policy599Provider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "policy599-local"
    private var configurationMaterial: String? = "policy599-fixed-local"
    var runtimeConfigurationMaterial: String? {
        get { lock.withLock { configurationMaterial } }
        set { lock.withLock { configurationMaterial = newValue } }
    }
    let capabilities: Set<ProviderCapability> = [.tools]
    private let lock = NSLock()
    private var currentModel = LLMModel(id: "policy599", displayName: "Synthetic599", provider: "policy599-local")
    var model: LLMModel {
        get { lock.withLock { currentModel } }
        set { lock.withLock { currentModel = newValue } }
    }
    private var replies: [String] = []
    private var replyDelays: [Duration?] = []
    private var captured: [[LLMMessage]] = []
    private var capturedPrompts: [String] = []
    func configure(_ replies: [String], delays: [Duration?] = []) {
        lock.withLock {
            self.replies = replies
            replyDelays = delays
        }
    }
    func requests() -> [[LLMMessage]] { lock.withLock { captured } }
    func lastPrompt() -> String? { lock.withLock { capturedPrompts.last } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        let (reply, delay): (String?, Duration?) = lock.withLock {
            captured.append(messages)
            capturedPrompts.append(systemPrompt ?? "")
            let delay = replyDelays.isEmpty ? nil : replyDelays.removeFirst()
            return (replies.isEmpty ? nil : replies.removeFirst(), delay)
        }
        if let delay { try await Task.sleep(for: delay) }
        if let reply { return LLMResponse(text: reply, stopReason: "stop", usage: nil) }
        return LLMResponse(text: "工具结果已收到。", stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw CancellationError() // This provider does not advertise streaming.
    }
}

private final class Policy599GoalReviewer: LLMProvider, @unchecked Sendable {
    let name = "goal-review-fixture"
    var model = LLMModel(id: "review-model", displayName: "Review fixture", provider: "goal-review-fixture")
    private let passes: Bool
    private let lock = NSLock()

    private let delay: Duration?
    init(passes: Bool = true, delay: Duration? = nil) { self.passes = passes; self.delay = delay }
    private var textCount = 0
    private var nonTextCount = 0
    var counts: (text: Int, nonText: Int) { lock.withLock { (textCount, nonTextCount) } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { textCount += 1 }
        if let delay { try await Task.sleep(for: delay) }
        return .init(text: passes ? "VERDICT: PASS" : "VERDICT: FAIL Evidence incomplete", stopReason: "stop",
                     usage: .init(inputTokens: 9, outputTokens: 2))
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        lock.withLock { nonTextCount += 1 }
        throw CancellationError()
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        lock.withLock { nonTextCount += 1 }
        throw CancellationError()
    }
}

/// Retain the canonical Settings owner for the complete ordinary turn. An
/// ambient owner from another test/profile must not provide this fixture's context.
@MainActor
private struct Policy599Fixture {
    let bridge: BridgeStore
    let settings: SettingsCenter
}

@Suite("599 non-UI production policy consumers")
@MainActor
struct Policy599ProductionConsumerTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Policy599-" + UUID().uuidString)
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return root
    }
    private func makeBridge(root: URL, provider: Policy599Provider, approval: any ApprovalDelegate,
                            deadlineHorizon: TimeInterval = 600, preparedSkills: SkillStore? = nil) throws -> Policy599Fixture {
        let defaults = try #require(UserDefaults(suiteName: "policy599-" + UUID().uuidString))
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let now = Date()
        let lineage = ProviderReadinessLineage.derived(providerID: provider.name, modelID: provider.model.id, checkedAt: now)
        #expect(readiness.upsert([ProviderReadinessPersistenceRecord(providerID: provider.name,
            modelID: provider.model.id, status: .passed, readinessState: .mock, checkedAt: now,
            evidenceID: "policy599-owned-synthetic", isApplied: false,
            discoveryReceiptID: lineage.discoveryReceiptID, discoveredAt: lineage.discoveredAt)]))
        try #require(readiness.applyDiscoveredModels(providerID: provider.name,
            modelIDs: [provider.model.id], appliedAt: now.addingTimeInterval(1)).count == 1)
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            canvasFactory: { _ in preconditionFailure("599 is non-Canvas") },
            agentTaskStore: try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json")),
            contextManifestStore: try ContextManifestStore(persistenceURL: root.appendingPathComponent("manifests.json")),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            providerReadinessStore: readiness,
            taskCenterBindingPersistenceURL: root.appendingPathComponent("bindings.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
            })
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        let settings = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("providers"),
                                  keychain: KeychainStore(backing: InMemoryKeychainBacking())),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: sessions, sessionBadgeStore: badges,
            logManager: bridge.chat.logManager,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"),
                                        keychain: KeychainStore(backing: InMemoryKeychainBacking())),
            skillStore: preparedSkills ?? SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("policy599-usage-" + UUID().uuidString)),
            providerReadinessStore: readiness)
        try #require(SettingsCenter.active === settings)
        try #require(settings.sessionStore === sessions)
        try #require(bridge.chat.attachPersistence(sessions, badgeStore: badges))
        bridge.attachProductionServices(fileAccessAllowedRoot: root, fileAccessDeniedRoots: [],
            sessionDirectory: sessions.directory,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"),
                                        keychain: KeychainStore(backing: InMemoryKeychainBacking())),
            skillStore: preparedSkills ?? SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            approvalDelegateOverride: approval,
            policyDefaults: ProductionPolicyDefaults(budget: 100, deadlineHorizon: deadlineHorizon,
                                                     autonomyLevel: .l3, networkDomains: []),
            externalRunners: [:],
            sessionReadSecretStore: EnvVarStore(directory: root.appendingPathComponent("env"),
                                               keychain: KeychainStore(backing: InMemoryKeychainBacking())))
        try #require(bridge.chat.sessionStore === sessions)
        try #require(bridge.chat.sessionManager?.store === sessions)
        try #require(bridge.chat.sessionManager?.badgeStore === badges)
        try #require(bridge.chat.agentEngine is AgentLoopChatEngine)
        bridge.updateApprovalPolicy(.autoApprove)
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.composerSubmissionDiagnosticsEnabled = true
        return Policy599Fixture(bridge: bridge, settings: settings)
    }
    private func call(_ id: String, _ name: String, _ input: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["tool_calls": [[
            "id": id, "name": name, "input": input]]]), as: UTF8.self)
    }
    private func submit(_ bridge: BridgeStore, _ provider: Policy599Provider, replies: [String],
                        mode: ComposerTaskMode, scope: ComposerApprovalScope = .request,
                        delays: [Duration?] = [], requiresFinalProviderRequest: Bool = true,
                        interactive: Bool = false, draft: String = "599 owned synthetic operation") async throws -> [LLMMessage] {
        let before = provider.requests().count
        provider.configure(replies, delays: delays)
        bridge.chat.composerPolicySelection = ComposerPolicySelection(mode: mode, approvalScope: scope,
            effort: .standard, bypassModeConfirmed: false)
        bridge.chat.draftText = draft
        if interactive {
            bridge.chat.selectInteractiveComposerMode(mode)
            bridge.chat.submitInteractiveComposer()
        } else {
            bridge.chat.submitComposer()
        }
        for _ in 0..<500 {
            if !bridge.chat.isStreaming { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!bridge.chat.isStreaming)
        if requiresFinalProviderRequest && provider.requests().count != before + replies.count + 1 {
            let stages = bridge.chat.logManager.recentLogs().filter {
                $0.category == "ComposerSubmission"
            }.reversed().map(\.message)
            let assistant = bridge.chat.messages.filter { $0.role == .assistant }.map(\.content)
            print("POLICY599_DIAGNOSTIC mode=\(mode.rawValue) scope=\(scope.rawValue) providerRequests=\(provider.requests().count) expected=\(before + replies.count + 1) streaming=\(bridge.chat.isStreaming) networkAllowed=\(bridge.productionExternalNetworkAllowed)")
            print("POLICY599_DIAGNOSTIC stages=\(stages) assistant=\(assistant) feedback=\(bridge.chat.pastedTextActionFeedback ?? "none")")
        }
        if requiresFinalProviderRequest {
            try #require(provider.requests().count == before + replies.count + 1)
        }
        return try #require(provider.requests().last)
    }
    private func terminal(_ messages: [LLMMessage], id: String) throws -> (String, Bool) {
        let values = messages.flatMap { $0.toAgentContentParts() }.compactMap { part -> (String, Bool)? in
            guard case .toolResult(let callID, _, let content, let error, _, _, _, _) = part,
                  callID == id else { return nil }
            return (content, error)
        }
        try #require(values.count == 1)
        return try #require(values.first)
    }
    private func reopened(_ bridge: BridgeStore) throws -> MinisCore.ChatSession {
        let directory = try #require(bridge.chat.sessionStore).directory
        let id = try #require(bridge.chat.activeSessionID)
        return try #require(SessionStore(directory: directory).loadSession(id: id.uuidString))
    }

    @Test func ordinaryTurnsListEnabledSkillsAndKeepAtMostTwoInTheirOwnSession() async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let skillStore = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let skills = ["Quartz", "Copper", "Granite", "Basalt"]
        for name in skills + ["Hidden"] {
            let imported = try skillStore.importSkillThroughLifecycle(
                content: """
                ---
                name: \(name)
                description: purpose \(name.lowercased())
                ---
                BODY_MARKER_\(name)
                """, source: .bundled, reason: "owned skill fixture",
                approval: SkillApproval(approverID: "synthetic-skill-test")
            )
            if name == "Hidden" {
                skillStore.setEnabled(imported.skill.id, enabled: false)
            }
        }

        let fixture = try makeBridge(root: root, provider: provider, approval: approval, preparedSkills: skillStore)
        let bridge = fixture.bridge
        defer { bridge.chat.stopAllStreamingForSafety(); withExtendedLifetime(fixture) {} }
        for _ in 0..<500 where bridge.skillDeploymentStatus == .pending {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .ready = bridge.skillDeploymentStatus else {
            Issue.record("The owned skill deployment did not reach readiness")
            return
        }

        _ = try await submit(bridge, provider, replies: [], mode: .manual, interactive: true,
                             draft: "quartz copper granite basalt")
        let first = try #require(provider.lastPrompt())
        let injected = bridge.chat.lastSkillInjectionReceipts.filter(\.injected)
        try #require(injected.count == 3, "the real prompt must use exactly three of four eligible skill bodies")
        #expect(injected.reduce(0) { $0 + $1.injectedCharacters } <= 3_000)
        #expect(skills.filter { first.contains("BODY_MARKER_" + $0) }.count == 3)
        for name in skills {
            #expect(first.components(separatedBy: .newlines).contains {
                $0.contains(name) && $0.contains("purpose " + name.lowercased())
            })
        }
        #expect(!first.contains("purpose hidden"))

        _ = try await submit(bridge, provider, replies: [], mode: .manual, interactive: true, draft: "继续")
        let followup = try #require(provider.lastPrompt())
        #expect(skills.filter { followup.contains("BODY_MARKER_" + $0) }.count == 2)
        #expect(skills.allSatisfy { followup.contains("purpose " + $0.lowercased()) })

        bridge.chat.newSession()
        _ = try await submit(bridge, provider, replies: [], mode: .manual, interactive: true, draft: "继续")
        let other = try #require(provider.lastPrompt())
        #expect(skills.allSatisfy { !other.contains("BODY_MARKER_" + $0) })
        #expect(skills.allSatisfy { other.contains("purpose " + $0.lowercased()) })
    }

    @Test func onlyTheNextManualPromptReportsTheInterruptedTurn() async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        let bridge = fixture.bridge
        defer { bridge.chat.stopAllStreamingForSafety(); withExtendedLifetime(fixture) {} }
        provider.configure(["synthetic interrupted reply"], delays: [.seconds(15)])
        bridge.chat.selectInteractiveComposerMode(.manual)
        bridge.chat.draftText = "Start the synthetic turn"
        bridge.chat.submitInteractiveComposer()
        for _ in 0..<500 where provider.requests().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(provider.requests().count == 1 && bridge.chat.isStreaming)
        bridge.chat.stopStreaming()
        try #require(bridge.chat.messages.contains { $0.role == .assistant && $0.wasInterrupted })

        _ = try await submit(bridge, provider, replies: [], mode: .manual, interactive: true,
                             draft: "Continue after interruption")
        let first = try #require(provider.lastPrompt())
        #expect(first.contains("上一回合被用户中断"))
        _ = try await submit(bridge, provider, replies: [], mode: .manual, interactive: true,
                             draft: "Start another ordinary turn")
        let second = try #require(provider.lastPrompt())
        #expect(!second.contains("上一回合被用户中断"))
    }

    @Test func aUserOnlyTurnDoesNotRepeatAnOlderInterruption() async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        let bridge = fixture.bridge
        defer { bridge.chat.stopAllStreamingForSafety(); withExtendedLifetime(fixture) {} }
        provider.configure(["synthetic interrupted reply"], delays: [.seconds(15)])
        bridge.chat.selectInteractiveComposerMode(.manual)
        bridge.chat.draftText = "Start the synthetic turn"
        bridge.chat.submitInteractiveComposer()
        for _ in 0..<500 where provider.requests().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(provider.requests().count == 1 && bridge.chat.isStreaming)
        bridge.chat.stopStreaming()
        try #require(bridge.chat.messages.last?.wasInterrupted == true)
        bridge.chat.appendUser("An admitted user message without an assistant response")
        try #require(bridge.chat.messages.last?.role == .user)

        _ = try await submit(bridge, provider, replies: [], mode: .manual, interactive: true,
                             draft: "Start a new ordinary turn")
        let prompt = try #require(provider.lastPrompt())
        #expect(!prompt.contains("上一回合被用户中断"))
    }

    @Test func ordinaryPlanTurnEndsWithItsCurrentEnvironment() async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        let bridge = fixture.bridge
        defer { bridge.chat.stopAllStreamingForSafety(); withExtendedLifetime(fixture) {} }
        _ = try await submit(bridge, provider, replies: [], mode: .plan, interactive: true)
        let prompt = try #require(provider.lastPrompt())
        let environment = try #require(prompt.range(of: "当前日期：", options: .backwards))
        let tail = prompt[environment.lowerBound...]
        #expect(tail.contains("当前模型：" + provider.model.id))
        #expect(tail.contains("当前审批档位：计划"))
        #expect(tail.contains(AskUserQuestionTool.toolName))
        #expect(tail.contains("交给用户批准"))
    }

    @Test(arguments: [true, false])
    func acceptedManualGoalReportReviewsOnceAndRecordsOriginUsage(passes: Bool) async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        let bridge = fixture.bridge
        defer { bridge.chat.stopAllStreamingForSafety(); withExtendedLifetime(fixture) {} }
        let id = try #require(bridge.chat.activeSessionID)
        let goal = try bridge.chat.startConversationGoal(sessionID: id, objective: "Review the draft")
        // This test covers review accounting only; a rejected review would
        // otherwise start the next continuation turn and race the read below.
        _ = try bridge.chat.setConversationGoalAutoContinue(sessionID: id, goalID: goal.id, enabled: false)
        let reviewer = Policy599GoalReviewer(passes: passes)
        let snapshot = try ProviderRuntimeSnapshot(
            providerID: reviewer.name, modelID: reviewer.model.id,
            readinessEvidenceID: "synthetic-review-evidence",
            applyReceiptID: "provider-readiness-apply:synthetic-review"
        )
        let usageSuite = "policy599-review-usage-" + UUID().uuidString
        defer { UserDefaults(suiteName: usageSuite)?.removePersistentDomain(forName: usageSuite) }
        let usage = UsageStore(domain: .suite(usageSuite))
        bridge.chat.usageStore = usage
        bridge.chat.prepareGoalReviewPrimary = { sessionID in
            try #require(sessionID == id)
            return (snapshot, reviewer)
        }

        let priorSessionTokens = await bridge.chat.budgetTracker.budget.usedTokens
        let report = try call("goal599-report", "goal_update", [
            "action": "complete", "evidence": ["Draft": "Both sections reviewed"]
        ])
        let response = try await submit(bridge, provider, replies: [report], mode: .manual, interactive: true)
        try #require(!(try terminal(response, id: "goal599-report")).1)
        let requests = await approval.requests
        #expect(requests.map(\.callID) == ["goal599-report"])
        for _ in 0..<500 {
            if bridge.chat.conversationGoal(for: id)?.lastReview != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let saved = try #require(try reopened(bridge).goal)
        #expect(saved.id == goal.id)
        try #require(saved.status == (passes ? .completed : .active))
        #expect(saved.lastReview?.outcome == (passes ? .passed : .rejected))
        #expect(saved.lastReview?.provider == reviewer.name)
        #expect(saved.lastReview?.modelID == reviewer.model.id)
        #expect(saved.budget.usedTurns == 1)
        #expect(saved.budget.usedTokens == 11)
        let sessionTokens = await bridge.chat.budgetTracker.budget.usedTokens
        #expect(sessionTokens == priorSessionTokens + 11, "Review usage must be charged once to the original session")
        #expect(saved.budget.usedTokens <= sessionTokens)
        #expect(reviewer.counts.text == 1)
        #expect(reviewer.counts.nonText == 0)
        try #require(await usage.waitForPersistence())
        let reopenedUsage = UsageStore(domain: .suite(usageSuite))
        try #require(await reopenedUsage.waitForPersistence())
        let record = try #require(reopenedUsage.callHistory.first)
        #expect(reopenedUsage.totalCalls == 1 && reopenedUsage.callHistory.count == 1)
        #expect(record.inputTokens == 9 && record.outputTokens == 2)
        #expect(record.sessionID == id.uuidString)
        #expect(record.provider == reviewer.name && record.model == reviewer.model.id)
    }

    @Test(.serialized, arguments: ["exact", "repeat", "altered", "oversized", "pasted"])
    func manualRememberOnlyStagesTheExactUserFact(scenario: String) async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        try fixture.settings.provisionBuiltInMemoryCandidateSubmissions()
        let bridge = fixture.bridge
        defer { bridge.chat.stopAllStreamingForSafety(); withExtendedLifetime(fixture) {} }
        let sessionID = try #require(bridge.chat.activeSessionID)
        let handler = try #require(bridge.productionProjectSessionHandler)
        let project = root.appendingPathComponent("memory-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let projectID = try handler.authorizeFolderFromNativePicker(project)
        bridge.chat.setProject(ChatStore.SessionProject(id: projectID, name: "Synthetic project",
                                                       workingDirectory: project.path), forSession: sessionID)
        fixture.settings.memoryScopeProvider = { [weak chat = bridge.chat] in chat?.activeMemoryScope }
        let scope = MemoryScope(sessionID: sessionID.uuidString, projectID: projectID)
        try #require(bridge.chat.activeMemoryScope == scope)
        try #require(fixture.settings.memoryScopeProvider?() == scope)
        let trustedRoot = try #require(bridge.chat.trustedProjectRootProvider?(scope))
        guard case .resolved(let expectedRoot) = DarwinSystemPathResolver.resolveOutcome(project) else {
            Issue.record("The owned synthetic project could not be resolved")
            return
        }
        try #require(trustedRoot.path == expectedRoot)
        let fact = scenario == "oversized" ? String(repeating: "x", count: 513) : "The draft title is Blue Garden."
        let instruction = "Please remember this fact: " + fact
        let draft = scenario == "repeat" || scenario == "pasted" ? "Continue discussing the draft." : instruction
        if scenario == "pasted" {
            try #require(bridge.chat.setPastedTextDraft(PastedTextDraft(
                id: UUID(), text: instruction, source: .pasteboard, kind: .reference
            )))
        }
        let proposed = scenario == "altered" ? "The draft title is Red Garden." : fact
        let response = try call("remember599", "memory_propose_fact", ["fact": proposed])
        _ = try await submit(bridge, provider, replies: [response], mode: .manual,
                             requiresFinalProviderRequest: false, interactive: true, draft: draft)
        try #require(provider.requests().count >= 1)
        let pending = try fixture.settings.pendingMemoryProposals()
        #expect(pending.count == (scenario == "exact" ? 1 : 0))
        #expect(try fixture.settings.memoryStore.activeFacts().isEmpty)
        if scenario == "exact" {
            let facts = try #require((bridge.chat.agentEngine as? AgentLoopChatEngine)?.toolExecutionFactLedger.facts)
            #expect(facts.contains {
                $0.toolName == "memory_propose_fact" && $0.toolCallID == "remember599"
                    && $0.executionIdentity?.turn.sessionID == sessionID.uuidString && $0.status == .succeeded
            })
            #expect(throws: MemoryProposalConsumerError.invalidProvenance) {
                try fixture.settings.memoryProposalConsumer.submit(
                    text: fact, within: scope, sourceID: MemoryProposalConsumer.chatProjectSourceID
                )
            }
            let candidate = try #require(pending.first)
            try fixture.settings.approveDisplayedMemoryProposal(candidate)
            #expect(throws: MemoryProposalConsumerError.self) {
                try fixture.settings.approveDisplayedMemoryProposal(candidate)
            }
            let stored = try #require(fixture.settings.memoryStore.activeFacts().first)
            #expect(stored.visibility == .project)
            #expect(stored.text == fact)
            let reopenedStore = MemoryStore(directory: fixture.settings.memoryStore.directory)
            let reopenedProposals = MemoryProposalConsumer(store: reopenedStore)
            _ = try reopenedProposals.recoverApprovedProposals()
            let saved = try #require(try reopenedProposals.envelopes().first {
                $0.proposal.proposalID == candidate.proposal.proposalID
            })
            #expect(saved.state == .active)
            #expect(saved.approvalReceipt?.reason == "用户在设置中批准对话记忆")

            let revoked = try fixture.settings.setMemoryCandidateSubmission(for: .userRequestedChatFact, enabled: false)
            let reprovisioned = try fixture.settings.provisionBuiltInMemoryCandidateSubmissions()
            #expect(reprovisioned.first { $0.sourceID == MemoryProposalConsumer.chatProjectSourceID } == revoked)
            #expect(try !fixture.settings.memoryCandidateSubmissionEnabled(for: .userRequestedChatFact))
            let before = try reopenedProposals.envelopes()
            _ = try await submit(bridge, provider,
                                 replies: [call("rememberRevoked599", "memory_propose_fact", ["fact": proposed])],
                                 mode: .manual, interactive: true, draft: draft)
            let revokedTerminal = try terminal(try #require(provider.requests().last), id: "rememberRevoked599")
            #expect(revokedTerminal.1)
            #expect(revokedTerminal.0.contains("已在设置中停用对话记忆候选"))
            #expect(try reopenedProposals.envelopes() == before)
            #expect(try fixture.settings.memoryStore.activeFacts() == [stored])

            bridge.chat.memoryInjector = MemoryInjector(store: reopenedStore)
            bridge.chat.memoryEnabledProvider = { true }
            let otherProject = root.appendingPathComponent("foreign-memory-project", isDirectory: true)
            try FileManager.default.createDirectory(at: otherProject, withIntermediateDirectories: false)
            let otherProjectID = try handler.authorizeFolderFromNativePicker(otherProject)
            for (directory, authorisedID, expected) in [(project, projectID, true), (otherProject, otherProjectID, false)] {
                bridge.chat.newSession()
                let nextID = try #require(bridge.chat.activeSessionID)
                try #require(nextID != sessionID)
                bridge.chat.setProject(ChatStore.SessionProject(id: authorisedID, name: "Synthetic project",
                                                                workingDirectory: directory.path), forSession: nextID)
                let nextScope = MemoryScope(sessionID: nextID.uuidString, projectID: authorisedID)
                try #require(bridge.chat.activeMemoryScope == nextScope)
                try #require(bridge.chat.trustedProjectRootProvider?(nextScope) != nil)
                _ = try await submit(bridge, provider, replies: [], mode: .manual,
                                     interactive: true, draft: "What is the draft title?")
                let prompt = try #require(provider.lastPrompt())
                #expect(prompt.contains(fact) == expected)
            }
        }
    }

    @Test func manualDeniedReadCardPreservesTargetThroughComposerRebuild() async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        let bridge = fixture.bridge
        defer { bridge.chat.stopAllStreamingForSafety(); withExtendedLifetime(fixture) {} }
        // Outside the isolated fixture's permitted root, so manual mode must ask.
        // This path is synthetic and is never created or read.
        let callID = "read-display599"
        let input: [String: Any] = ["path": "/owned/a/report.md", "offset": 1, "lines": 20]
        let response = try await submit(bridge, provider, replies: [call(callID, "file_read", input)], mode: .manual)
        try #require(try terminal(response, id: callID).1)
        let requests = await approval.requests
        try #require(requests.count == 1)
        let request = try #require(requests.first)
        let snapshot = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        let toolInput = try ComposerToolInput(input)
        let binding = snapshot.callSnapshot(callID: callID, input: toolInput)
        #expect(request.callID == callID && request.sessionID == snapshot.sessionID)
        #expect(request.inputDigest == toolInput.digest && request.identityDigest == binding.identityDigest)
        let summary = ApprovalSummaryPresentation(request: request)
        #expect(summary.target == "report.md")
        #expect(summary.directory == "/owned/a")
    }

    @Test(arguments: [false, true])
    func dryRunAndDeniedActualChatNeverClaimSuccessfulEffect(plan: Bool) async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 0)
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        defer { withExtendedLifetime(fixture) {} }
        let bridge = fixture.bridge
        let target = root.appendingPathComponent("must-not-exist.txt")
        let request = try await submit(bridge, provider,
            replies: [call("deny599", "file_write", ["path": target.path, "content": "owned599"])],
            mode: plan ? .plan : .manual)
        let result = try terminal(request, id: "deny599")
        #expect(result.1)
        if plan { #expect(result.0.contains("dry-run")) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.toolExecutionFactLedger.facts.isEmpty)
        #expect(engine.toolExecutionFactLedger.pendingReceipts.isEmpty)
        #expect(await approval.requests.count == (plan ? 0 : 1))
        #expect(bridge.composerApprovalReceipts.isEmpty)
        let restored = try reopened(bridge)
        #expect(restored.id == bridge.chat.activeSessionID?.uuidString)
        let liveMessages = bridge.chat.messages.map { $0.asLLMMessage() }
        let restoredSameMessages = restored.messages == liveMessages
        #expect(restoredSameMessages)
        let fixedStatus = plan
            ? "计划模式：1 项工具调用未执行"
            : "执行前拦截：1 项工具调用未执行"
        #expect(restored.messages.contains {
            $0.role == .assistant && $0.content.contains(fixedStatus)
        })
        #expect(!restored.messages.contains { $0.content.contains("执行成功") })
    }

    @Test func outOfRootPolicyDenialPersistsUnexecutedStatusWithoutEffect() async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 0)
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        defer { withExtendedLifetime(fixture) {} }
        let bridge = fixture.bridge
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("Policy599-outside-" + UUID().uuidString + ".txt")
        try "sentinel599".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        let request = try await submit(bridge, provider,
            replies: [call("outside599", "file_write", ["path": outside.path, "content": "changed599"])],
            mode: .autoEdit)
        let result = try terminal(request, id: "outside599")
        #expect(result.1)
        #expect(result.0.contains("outside allowed roots"))
        #expect(try String(contentsOf: outside, encoding: .utf8) == "sentinel599")
        #expect(await approval.requests.isEmpty)
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.toolExecutionFactLedger.facts.isEmpty)
        #expect(engine.toolExecutionFactLedger.pendingReceipts.isEmpty)
        #expect(bridge.composerApprovalReceipts.isEmpty)
        let restored = try reopened(bridge)
        #expect(restored.messages == bridge.chat.messages.map { $0.asLLMMessage() })
        #expect(restored.messages.contains {
            $0.role == .assistant && $0.content.contains("执行前拦截：1 项工具调用未执行")
        })
        #expect(!restored.messages.contains { $0.content.contains(outside.path) })
    }

    @Test(arguments: [ComposerTaskMode.autoEdit, .auto])
    func autoEditWritesEditsActualFilesButDeniesOtherEffects(mode: ComposerTaskMode) async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 0)
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        defer { withExtendedLifetime(fixture) {} }
        let bridge = fixture.bridge
        bridge.updateApprovalPolicy(.alwaysAsk)
        let target = root.appendingPathComponent("actual.txt"), shellTarget = root.appendingPathComponent("no-shell.txt")
        let request = try await submit(bridge, provider, replies: [
            call("write599", "file_write", ["path": target.path, "content": "before599"]),
            call("edit599", "file_edit", ["path": target.path, "old_string": "before599", "new_string": "after599"]),
            call("shell599", "shell_execute", ["command": "printf owned599 > '" + shellTarget.path + "'"])
        ], mode: mode, interactive: true)
        #expect(try String(contentsOf: target, encoding: .utf8) == "after599")
        #expect(!(try terminal(request, id: "write599")).1)
        #expect(!(try terminal(request, id: "edit599")).1)
        #expect((try terminal(request, id: "shell599")).1)
        let approvalRequests = await approval.requests
        #expect(approvalRequests.map(\.toolName) == ["shell_execute"])
        let shellApproval = try #require(approvalRequests.first)
        let snapshot = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        #expect(shellApproval.requiresApproval)
        #expect(shellApproval.callID == "shell599")
        #expect(shellApproval.composerMode == mode.rawValue)
        #expect(snapshot.explicitlySelectedInteractiveAutoMode)
        #expect(shellApproval.sessionID == snapshot.sessionID)
        #expect(shellApproval.turnID == snapshot.turnID)
        #expect(shellApproval.taskID == snapshot.taskID)
        #expect(shellApproval.policyRevision == snapshot.policyRevision)
        #expect(shellApproval.grantEpoch == snapshot.grantEpoch)
        #expect(shellApproval.identityDigest != nil && shellApproval.inputDigest != nil)
        #expect(bridge.composerApprovalReceipts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: shellTarget.path))
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let facts = engine.toolExecutionFactLedger.facts
        #expect(facts.count == 2)
        #expect(Set(facts.map(\.toolCallID)) == Set(["write599", "edit599"]))
        #expect(Set(facts.map(\.toolName)) == Set(["file_write", "file_edit"]))
        #expect(facts.allSatisfy { $0.status == .succeeded })
        #expect(engine.toolExecutionFactLedger.pendingReceipts.isEmpty)
        let restored = try reopened(bridge)
        #expect(restored.messages == bridge.chat.messages.map { $0.asLLMMessage() })
        #expect(try Data(contentsOf: target) == Data("after599".utf8))
        #expect(!FileManager.default.fileExists(atPath: shellTarget.path))
    }

    /// A3: the global autoEdit/auto choice (also after a restart, where no explicit
    /// Composer selection happened) applies to every user-sent turn.
    @Test(arguments: [ComposerTaskMode.autoEdit, .auto])
    func restoredAutoModeDoesNotAskForUserSentWorkspaceWrite(mode: ComposerTaskMode) async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 0)
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        defer { withExtendedLifetime(fixture) {} }
        let bridge = fixture.bridge
        bridge.updateApprovalPolicy(.alwaysAsk)
        bridge.chat.restoreComposerPolicy(ComposerPolicySettings(mode: mode))
        let target = root.appendingPathComponent("restored-default.txt")
        provider.configure([try call("restored-write", "file_write", ["path": target.path, "content": "allowed599"])])
        bridge.chat.draftText = "599 restored Composer mode"
        bridge.chat.submitInteractiveComposer()
        try await settle(bridge, provider, requests: 2)
        let snapshot = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        #expect(snapshot.mode == mode)
        #expect(snapshot.explicitlySelectedInteractiveAutoMode)
        #expect(await approval.requests.isEmpty)
        #expect(try String(contentsOf: target, encoding: .utf8) == "allowed599")
        try expectSingleSucceededWrite(bridge, id: "restored-write")
    }

    @Test func queuedUserMessageInAutoEditWritesWithoutAsking() async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 0)
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        defer { withExtendedLifetime(fixture) {} }
        let bridge = fixture.bridge
        bridge.updateApprovalPolicy(.alwaysAsk)
        bridge.chat.restoreComposerPolicy(ComposerPolicySettings(mode: .autoEdit))
        let target = root.appendingPathComponent("queued.txt")
        provider.configure(["first answer", try call("queued-write", "file_write",
            ["path": target.path, "content": "queued599"])], delays: [.milliseconds(300)])
        bridge.chat.draftText = "first turn"
        bridge.chat.submitInteractiveComposer()
        try await waitUntilRequests(provider, 1)
        bridge.chat.draftText = "queued turn"
        try #require(bridge.chat.enqueueComposer())
        try await settle(bridge, provider, requests: 3)
        #expect(bridge.chat.activeQueuedComposerMessages.isEmpty)
        let snapshot = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        #expect(snapshot.mode == .autoEdit && snapshot.explicitlySelectedInteractiveAutoMode)
        #expect(await approval.requests.isEmpty)
        #expect(try String(contentsOf: target, encoding: .utf8) == "queued599")
        try expectSingleSucceededWrite(bridge, id: "queued-write")
    }

    @Test func interruptAndResendInAutoEditWritesWithoutAsking() async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 0)
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        defer { withExtendedLifetime(fixture) {} }
        let bridge = fixture.bridge
        bridge.updateApprovalPolicy(.alwaysAsk)
        bridge.chat.restoreComposerPolicy(ComposerPolicySettings(mode: .autoEdit))
        let target = root.appendingPathComponent("resent.txt")
        provider.configure(["slow answer", try call("resend-write", "file_write",
            ["path": target.path, "content": "resent599"])], delays: [.seconds(5)])
        bridge.chat.draftText = "first turn"
        bridge.chat.submitInteractiveComposer()
        try await waitUntilRequests(provider, 1)
        bridge.chat.draftText = "interrupt and resend"
        bridge.chat.interruptAndSend()
        try await settle(bridge, provider, requests: 3)
        let snapshot = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        #expect(snapshot.mode == .autoEdit && snapshot.explicitlySelectedInteractiveAutoMode)
        #expect(await approval.requests.isEmpty)
        #expect(try String(contentsOf: target, encoding: .utf8) == "resent599")
        try expectSingleSucceededWrite(bridge, id: "resend-write")
    }

    @Test func approvedPlanExecutionInAutoEditWritesWithoutAsking() async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 0)
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        defer { withExtendedLifetime(fixture) {} }
        let bridge = fixture.bridge
        bridge.updateApprovalPolicy(.alwaysAsk)
        _ = try await submit(bridge, provider, replies: [], mode: .plan, draft: "599 plan turn")
        let proposal = try #require(bridge.chat.activePlanApproval)
        let target = root.appendingPathComponent("planned.txt")
        provider.configure([try call("plan-write", "file_write", ["path": target.path, "content": "planned599"])])
        let before = provider.requests().count
        #expect(await bridge.chat.resolvePlanApproval(.approveAutoEdit, proposalID: proposal.id))
        try await settle(bridge, provider, requests: before + 2)
        let snapshot = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        #expect(snapshot.mode == .autoEdit && snapshot.explicitlySelectedInteractiveAutoMode)
        #expect(await approval.requests.isEmpty)
        #expect(try String(contentsOf: target, encoding: .utf8) == "planned599")
        try expectSingleSucceededWrite(bridge, id: "plan-write")
    }

    @Test func goalContinuationInAutoEditWritesWithoutAsking() async throws {
        let approval = Policy599Approval(approvals: 0)
        let run = try goalRun(mode: .autoEdit, approval: approval)
        defer { run.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: run.root) }
        run.fixture.bridge.updateApprovalPolicy(.alwaysAsk)
        // A restart leaves only the global autoEdit choice.
        run.chat.restoreComposerPolicy(ComposerPolicySettings(mode: .autoEdit))
        let first = run.root.appendingPathComponent("goal-first.txt")
        let second = run.root.appendingPathComponent("goal-second.txt")
        run.provider.configure([try call("goal-w1", "file_write", ["path": first.path, "content": "g1"]),
                                "first done",
                                try call("goal-w2", "file_write", ["path": second.path, "content": "g2"])])
        run.chat.draftText = "开始推进目标"
        run.chat.submitInteractiveComposer()
        try await waitForGoalQuiet(run)
        #expect(userTexts(run).contains { $0.hasPrefix("〔目标续跑〕") })
        let continuation = try #require(run.chat.lastComposerSubmissionSnapshot)
        #expect(continuation.mode == .autoEdit && continuation.explicitlySelectedInteractiveAutoMode)
        #expect(await approval.requests.isEmpty)
        #expect(try String(contentsOf: first, encoding: .utf8) == "g1")
        #expect(try String(contentsOf: second, encoding: .utf8) == "g2")
        let engine = try #require(run.chat.agentEngine as? AgentLoopChatEngine)
        #expect(Set(engine.toolExecutionFactLedger.facts.map(\.toolCallID)) == Set(["goal-w1", "goal-w2"]))
        #expect(engine.toolExecutionFactLedger.facts.allSatisfy { $0.status == .succeeded })
    }

    /// A turn that is not marked user-started (the same shape scheduled and
    /// unattended admissions get: no explicit flag) still asks in autoEdit.
    @Test func turnWithoutUserInitiationInAutoEditStillAsksForWorkspaceWrite() async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 0)
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        defer { withExtendedLifetime(fixture) {} }
        let bridge = fixture.bridge
        bridge.updateApprovalPolicy(.alwaysAsk)
        let target = root.appendingPathComponent("not-user.txt")
        let request = try await submit(bridge, provider,
            replies: [call("nouser-write", "file_write", ["path": target.path, "content": "blocked599"])],
            mode: .autoEdit, interactive: false)
        #expect((try terminal(request, id: "nouser-write")).1)
        let snapshot = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        #expect(snapshot.mode == .autoEdit && !snapshot.explicitlySelectedInteractiveAutoMode)
        #expect(await approval.requests.map(\.callID) == ["nouser-write"])
        #expect(!FileManager.default.fileExists(atPath: target.path))
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.toolExecutionFactLedger.facts.isEmpty)
    }

    @Test func manualModeStillAsksForUserSentWorkspaceWrite() async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 0)
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        defer { withExtendedLifetime(fixture) {} }
        let bridge = fixture.bridge
        bridge.chat.restoreComposerPolicy(ComposerPolicySettings(mode: .manual))
        let target = root.appendingPathComponent("manual.txt")
        provider.configure([try call("manual-write", "file_write", ["path": target.path, "content": "blocked599"])])
        bridge.chat.draftText = "599 manual"
        bridge.chat.submitInteractiveComposer()
        try await settle(bridge, provider, requests: 2)
        let snapshot = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        #expect(snapshot.mode == .manual && !snapshot.explicitlySelectedInteractiveAutoMode)
        #expect(await approval.requests.map(\.callID) == ["manual-write"])
        #expect(!FileManager.default.fileExists(atPath: target.path))
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.toolExecutionFactLedger.facts.isEmpty)
    }

    private func waitUntilRequests(_ provider: Policy599Provider, _ count: Int) async throws {
        for _ in 0..<500 {
            if provider.requests().count >= count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(provider.requests().count >= count)
    }

    private func settle(_ bridge: BridgeStore, _ provider: Policy599Provider, requests: Int) async throws {
        try await waitUntilRequests(provider, requests)
        for _ in 0..<500 {
            if !bridge.chat.isStreaming && bridge.chat.activeQueuedComposerMessages.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!bridge.chat.isStreaming)
        try #require(provider.requests().count == requests)
    }

    private func expectSingleSucceededWrite(_ bridge: BridgeStore, id: String) throws {
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let facts = engine.toolExecutionFactLedger.facts
        #expect(facts.map(\.toolCallID) == [id])
        #expect(facts.allSatisfy { $0.status == .succeeded && $0.toolName == "file_write" })
        #expect(engine.toolExecutionFactLedger.pendingReceipts.isEmpty)
    }

    @Test(arguments: ComposerApprovalScope.allCases)
    func fourScopesUseRealEffectsAndRejectForeignSession(scope: ComposerApprovalScope) async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 1)
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        defer { withExtendedLifetime(fixture) {} }
        let bridge = fixture.bridge
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        let c = root.appendingPathComponent("c.txt"), d = root.appendingPathComponent("d.txt")
        _ = try await submit(bridge, provider, replies: [
            call("scope-a", "file_write", ["path": a.path, "content": "a"]),
            call("scope-b", "file_write", ["path": b.path, "content": "b"])
        ], mode: .manual, scope: scope)
        let firstSnapshot = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        try #require(bridge.composerApprovalReceipts.count == 1)
        let approved = try #require(bridge.composerApprovalReceipts.first)
        let originalRequest = try #require(await approval.requests.first)
        #expect(approved.requestID == originalRequest.requestID)
        #expect(approved.callID == "scope-a")
        #expect(approved.approvalScope == scope && approved.mode == .manual)
        #expect(approved.sessionID == firstSnapshot.sessionID)
        #expect(approved.turnID == firstSnapshot.turnID && approved.taskID == firstSnapshot.taskID)
        #expect(approved.attemptID == firstSnapshot.attemptID && approved.messageID == firstSnapshot.messageID)
        #expect(approved.policyRevision == firstSnapshot.policyRevision && approved.grantEpoch == firstSnapshot.grantEpoch)
        #expect(approved.leaseID == bridge.chat.composerPolicyFacts.leaseID && !approved.leaseRevoked)
        #expect(try String(contentsOf: a, encoding: .utf8) == "a")
        #expect(FileManager.default.fileExists(atPath: b.path) == (scope != .request))
        _ = try await submit(bridge, provider, replies: [call("scope-c", "file_write", ["path": c.path, "content": "c"])],
                             mode: .manual, scope: scope)
        #expect(FileManager.default.fileExists(atPath: c.path) == (scope == .session || scope == .workspace))
        let oldSession = try #require(bridge.chat.activeSessionID)
        bridge.chat.newSession()
        try #require(bridge.chat.activeSessionID != oldSession)
        _ = try await submit(bridge, provider, replies: [call("scope-d", "file_write", ["path": d.path, "content": "d"])],
                             mode: .manual, scope: scope)
        #expect(FileManager.default.fileExists(atPath: d.path) == (scope == .workspace))
        let expectedApprovals = switch scope { case .request: 4; case .turn: 3; case .session: 2; case .workspace: 1 }
        #expect(await approval.requests.count == expectedApprovals)
        #expect(bridge.composerApprovalReceipts == [approved])
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.toolExecutionFactLedger.facts.count == 5 - expectedApprovals)
        #expect(engine.toolExecutionFactLedger.facts.allSatisfy { $0.status == .succeeded })
        let restored = try reopened(bridge)
        #expect(restored.id == bridge.chat.activeSessionID?.uuidString)
        #expect(try Data(contentsOf: a) == Data("a".utf8))
        // A distinct public App composition is a distinct workspace authority.
        // Original shared-store cross-workspace/revision predicates remain in
        // ComposerApprovalModeTests; this adds the actual App boundary/effect.
        let foreignRoot = try makeRoot(), foreignProvider = Policy599Provider()
        let foreignApproval = Policy599Approval(approvals: 0)
        let foreignFixture = try makeBridge(root: foreignRoot, provider: foreignProvider, approval: foreignApproval)
        defer { withExtendedLifetime(foreignFixture) {} }
        let foreign = foreignFixture.bridge
        #expect(foreign.chat.composerWorkspaceID != bridge.chat.composerWorkspaceID)
        let foreignFile = foreignRoot.appendingPathComponent("foreign.txt")
        let foreignRequest = try await submit(foreign, foreignProvider,
            replies: [call("foreign599", "file_write", ["path": foreignFile.path, "content": "foreign"])],
            mode: .manual, scope: scope)
        #expect((try terminal(foreignRequest, id: "foreign599")).1)
        #expect(await foreignApproval.requests.count == 1)
        #expect(foreign.composerApprovalReceipts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: foreignFile.path))
        let foreignEngine = try #require(foreign.chat.agentEngine as? AgentLoopChatEngine)
        #expect(foreignEngine.toolExecutionFactLedger.facts.isEmpty)
        _ = try reopened(foreign)
    }

    @Test(arguments: [ComposerApprovalScope.session, .workspace])
    func scopedConsentCarriesAcrossFreshTaskLeaseWithinChosenScope(
        scope: ComposerApprovalScope
    ) async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 1)
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        defer { withExtendedLifetime(fixture) {} }
        let bridge = fixture.bridge
        let a = root.appendingPathComponent("consent-a.txt")
        let b = root.appendingPathComponent("consent-b.txt")
        let c = root.appendingPathComponent("consent-c.txt")
        let first = try await submit(bridge, provider,
            replies: [call("consent-a", "file_write", ["path": a.path, "content": "a"])],
            mode: .manual, scope: scope)
        #expect(!(try terminal(first, id: "consent-a")).1)
        #expect(try String(contentsOf: a, encoding: .utf8) == "a")
        let firstSnapshot = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        let firstLease = bridge.chat.composerPolicyFacts.leaseID
        #expect(await approval.requests.count == 1)

        let second = try await submit(bridge, provider,
            replies: [call("consent-b", "file_write", ["path": b.path, "content": "b"])],
            mode: .manual, scope: scope)
        let secondSnapshot = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        #expect(secondSnapshot.grantEpoch != firstSnapshot.grantEpoch)
        #expect(bridge.chat.composerPolicyFacts.leaseID != firstLease)
        #expect(!(try terminal(second, id: "consent-b")).1)
        #expect(try String(contentsOf: b, encoding: .utf8) == "b")
        #expect(await approval.requests.count == 1)

        let oldSession = try #require(bridge.chat.activeSessionID)
        bridge.chat.newSession()
        try #require(bridge.chat.activeSessionID != oldSession)
        let third = try await submit(bridge, provider,
            replies: [call("consent-c", "file_write", ["path": c.path, "content": "c"])],
            mode: .manual, scope: scope)
        let thirdSnapshot = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        #expect(thirdSnapshot.grantEpoch != secondSnapshot.grantEpoch)
        #expect((try terminal(third, id: "consent-c")).1 == (scope == .session))
        #expect(FileManager.default.fileExists(atPath: c.path) == (scope == .workspace))
        #expect(await approval.requests.count == (scope == .session ? 2 : 1))
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.toolExecutionFactLedger.facts.count == (scope == .session ? 2 : 3))
    }

    @Test func workspaceGrantDoesNotSurviveProductionPolicyEpochRotation() async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 1)
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        defer { withExtendedLifetime(fixture) {} }
        let bridge = fixture.bridge
        let grantStore = bridge.chat.composerGrantStore
        let workspaceID = bridge.chat.composerWorkspaceID
        let before = root.appendingPathComponent("epoch-before.txt")
        let after = root.appendingPathComponent("epoch-after.txt")
        let first = try await submit(bridge, provider,
            replies: [call("epoch-before", "file_write", ["path": before.path, "content": "granted"])],
            mode: .manual, scope: .workspace)
        #expect(!(try terminal(first, id: "epoch-before")).1)
        #expect(try String(contentsOf: before, encoding: .utf8) == "granted")
        let oldFacts = bridge.chat.composerPolicyFacts
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.toolExecutionFactLedger.facts.count == 1)

        // This is the live App policy change, on the same Bridge and grant
        // store. Workspace identity is immutable in production; changing it
        // by test override would not exercise an actual App consumer.
        bridge.updateApprovalPolicy(.alwaysAsk)
        #expect(bridge.chat.composerGrantStore === grantStore)
        #expect(bridge.chat.composerWorkspaceID == workspaceID)
        #expect(bridge.chat.composerPolicyFacts.revision != oldFacts.revision)
        #expect(bridge.chat.composerPolicyFacts.grantEpoch != oldFacts.grantEpoch)
        let second = try await submit(bridge, provider,
            replies: [call("epoch-after", "file_write", ["path": after.path, "content": "must-not-write"])],
            mode: .manual, scope: .workspace)
        #expect((try terminal(second, id: "epoch-after")).1)
        #expect(await approval.requests.count == 2)
        #expect(!FileManager.default.fileExists(atPath: after.path))
        #expect(engine.toolExecutionFactLedger.facts.count == 1)
        #expect(engine.toolExecutionFactLedger.facts.allSatisfy { $0.status == .succeeded })
        let restored = try reopened(bridge)
        #expect(restored.messages == bridge.chat.messages.map { $0.asLLMMessage() })
        let final = try #require(restored.messages.last(where: { $0.role == .assistant }))
        #expect(final.content.contains("执行前拦截：1 项工具调用未执行"))
    }

    @Test func expiredProductionLeaseRequiresFreshTaskApprovalAndPersistsDenial() async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 1)
        let fixture = try makeBridge(root: root, provider: provider, approval: approval,
                                    deadlineHorizon: 4)
        defer { withExtendedLifetime(fixture) {} }
        let bridge = fixture.bridge
        let before = root.appendingPathComponent("lease-before.txt")
        let after = root.appendingPathComponent("lease-after.txt")
        let first = try await submit(bridge, provider,
            replies: [call("lease-before", "file_write", ["path": before.path, "content": "granted"])],
            mode: .manual, scope: .workspace)
        #expect(!(try terminal(first, id: "lease-before")).1)
        #expect(try String(contentsOf: before, encoding: .utf8) == "granted")
        let firstSnapshot = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        let firstLeaseID = bridge.chat.composerPolicyFacts.leaseID
        let expiry = bridge.chat.composerPolicyFacts.expiresAt
        let remaining = expiry.timeIntervalSinceNow
        if remaining > 0 {
            try await Task.sleep(nanoseconds: UInt64((remaining + 0.1) * 1_000_000_000))
        }
        #expect(Date() > expiry)
        let providerCalls = provider.requests().count
        provider.configure([try call("lease-after", "file_write",
            ["path": after.path, "content": "must-not-write"])])
        bridge.chat.composerPolicySelection = ComposerPolicySelection(mode: .manual,
            approvalScope: .workspace, effort: .standard, bypassModeConfirmed: false)
        bridge.chat.draftText = "599 lease expiry operation"
        bridge.chat.submitComposer()
        for _ in 0..<500 {
            if !bridge.chat.isStreaming { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!bridge.chat.isStreaming)
        let secondSnapshot = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        #expect(secondSnapshot.grantEpoch != firstSnapshot.grantEpoch)
        #expect(bridge.chat.composerPolicyFacts.leaseID != firstLeaseID)
        #expect(bridge.chat.composerPolicyFacts.expiresAt > Date())
        #expect(provider.requests().count == providerCalls + 2)
        let requests = await approval.requests
        #expect(requests.count == 2)
        #expect(requests.last?.callID == "lease-after")
        #expect(requests.last?.grantEpoch == secondSnapshot.grantEpoch)
        #expect(bridge.composerApprovalReceipts.count == 1)
        #expect(!FileManager.default.fileExists(atPath: after.path))
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.toolExecutionFactLedger.facts.count == 1)
        let restored = try reopened(bridge)
        #expect(restored.messages == bridge.chat.messages.map { $0.asLLMMessage() })
        let final = try #require(restored.messages.last(where: { $0.role == .assistant }))
        #expect(final.content.contains("执行前拦截：1 项工具调用未执行"))
        #expect(!final.content.contains("本次请求未执行"))
    }

    @Test func expiryAfterRealEffectDoesNotClaimWholeRequestUnexecuted() async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 1)
        let fixture = try makeBridge(root: root, provider: provider, approval: approval,
                                    deadlineHorizon: 4)
        defer { withExtendedLifetime(fixture) {} }
        let bridge = fixture.bridge
        let before = root.appendingPathComponent("same-turn-before.txt")
        let after = root.appendingPathComponent("same-turn-after.txt")
        let request = try await submit(bridge, provider, replies: [
            call("same-turn-before", "file_write", ["path": before.path, "content": "real-effect"]),
            call("same-turn-after", "file_write", ["path": after.path, "content": "must-not-write"])
        // The 4s hard lease expires during the 5s response. A final model call
        // cannot be a prerequisite for checking durable partial-effect honesty.
        // Audit 20261028T0229: the captured second request precedes Tool2's
        // response. Observe its unregistered cancellation in the durable local
        // journal, not a terminal result requiring a prohibited third request.
        ], mode: .manual, scope: .workspace, delays: [nil, .seconds(5)],
            requiresFinalProviderRequest: false)
        #expect(Date() > bridge.chat.composerPolicyFacts.expiresAt)
        #expect(!(try terminal(request, id: "same-turn-before")).1)
        #expect(try String(contentsOf: before, encoding: .utf8) == "real-effect")
        #expect(!FileManager.default.fileExists(atPath: after.path))
        #expect(provider.requests().count == 2)
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.toolExecutionFactLedger.facts.count == 1)
        #expect(engine.toolExecutionFactLedger.facts.first?.status == .succeeded)
        #expect(engine.toolExecutionFactLedger.facts.first?.toolCallID == "same-turn-before")
        #expect(engine.toolExecutionFactLedger.pendingReceipts.isEmpty)
        let sessionDirectory = try #require(bridge.chat.sessionStore).directory
        let journal = try String(contentsOf: sessionDirectory.appendingPathComponent("tool-lifecycle-events-v1.journal"), encoding: .utf8)
        #expect(journal.contains("same-turn-before"))
        #expect(!journal.contains("same-turn-after"))
        let restored = try reopened(bridge)
        let final = restored.messages.last(where: { $0.role == .assistant })?.content ?? ""
        #expect(final.contains("请求已取消"))
        #expect(!final.contains("全部未执行"))
        #expect(!final.contains("本次请求未执行"))
        #expect(try Data(contentsOf: before) == Data("real-effect".utf8))
    }
}


// MARK: - Goal continuation (actual BridgeStore admission, approval and persistence)

/// Answers approvals with scripted statuses (the last one repeats), as a
/// user or an expired card would.
private actor GoalContinuationApproval: ApprovalDelegate {
    private var statuses: [ApprovalDecisionStatus]
    private(set) var requests: [ApprovalRequest] = []
    init(status: ApprovalDecisionStatus) { statuses = [status] }
    init(statuses: [ApprovalDecisionStatus]) { self.statuses = statuses }
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        let status = statuses.count > 1 ? statuses.removeFirst() : statuses[0]
        let approved = status == .approved
        // A denial is the card's own Deny action, as the real card reports it.
        let reason = approved ? nil
            : status == .denied ? ApprovalPromptCenter.userDenialReason : "synthetic \(status.rawValue)"
        return ApprovalDecision(approved: approved, reason: reason,
            confirmed: approved, status: status, requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

/// Response notification IDs observed through the existing channel.
@MainActor
private final class GoalNoticeLog {
    private(set) var ids: [String] = []
    private(set) var successIDs: [String] = []
    func record(_ id: String, failed: Bool) {
        ids.append(id)
        if !failed { successIDs.append(id) }
    }
    var goalIDs: [String] { ids.filter { $0.hasPrefix("goal:") } }
}

extension Policy599ProductionConsumerTests {
    @MainActor
    private struct GoalRun {
        let fixture: Policy599Fixture
        let root: URL
        let provider: Policy599Provider
        let sessionID: UUID
        let goal: ConversationGoalState
        var chat: ChatStore { fixture.bridge.chat }
    }

    private func goalRun(mode: ComposerTaskMode = .manual,
                         approval: any ApprovalDelegate = GoalContinuationApproval(status: .approved),
                         objective: String = "Write the goal marker file") throws -> GoalRun {
        let root = try makeRoot(), provider = Policy599Provider()
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        let chat = fixture.bridge.chat
        chat.composerPolicySelection = ComposerPolicySelection(mode: mode, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: mode == .bypassPermission)
        if mode == .autoEdit || mode == .auto { chat.selectInteractiveComposerMode(mode) }
        let id = try #require(chat.activeSessionID)
        let goal = try chat.startConversationGoal(sessionID: id, objective: objective)
        return GoalRun(fixture: fixture, root: root, provider: provider, sessionID: id, goal: goal)
    }

    /// The user's own first goal turn: one real tool call, then a plain answer.
    private func sendUserGoalTurn(_ run: GoalRun, replies: [String]? = nil, delays: [Duration?] = [],
                                  text: String = "开始推进目标") throws -> ComposerSubmissionSnapshot {
        let marker = run.root.appendingPathComponent("goal-marker.txt")
        run.provider.configure(try replies ?? [call("goal-write", "file_write",
            ["path": marker.path, "content": "marker"])], delays: delays)
        run.chat.draftText = text
        run.chat.submitInteractiveComposer()
        return try #require(run.chat.lastComposerSubmissionSnapshot)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// No turn runs and no continuation is waiting to start, and that stays true.
    private func waitForGoalQuiet(_ run: GoalRun) async throws {
        let quiet = { @MainActor in
            !run.chat.isStreaming && !run.chat.pendingGoalContinuationSessions.contains(run.sessionID)
        }
        try await waitUntil(quiet)
        try await Task.sleep(for: .milliseconds(200))
        try #require(quiet())
    }

    private func storedGoal(_ run: GoalRun) throws -> ConversationGoalState {
        let directory = try #require(run.chat.sessionStore).directory
        return try #require(SessionStore(directory: directory)
            .loadSession(id: run.sessionID.uuidString)?.goal)
    }

    private func userTexts(_ run: GoalRun) -> [String] {
        run.chat.messages.filter { $0.role == .user }.map(\.content)
    }

    @Test(arguments: [ComposerTaskMode.manual, .autoEdit, .auto, .bypassPermission])
    func completedGoalTurnContinuesOnceThroughUserAdmissionThenEmptyContinuationPauses(
        mode: ComposerTaskMode
    ) async throws {
        let run = try goalRun(mode: mode)
        defer { run.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: run.root) }
        let notices = GoalNoticeLog()
        run.chat.onResponseNotification = { _, id, failed in notices.record(id, failed: failed) }
        let userSnapshot = try sendUserGoalTurn(run)
        try await waitForGoalQuiet(run)

        // User turn: tool call + answer; continuation: one answer without tools.
        #expect(run.provider.requests().count == 3)
        let texts = userTexts(run)
        try #require(texts.count == 2)
        #expect(texts[0] == "开始推进目标")
        #expect(texts[1].hasPrefix("〔目标续跑〕"))
        #expect(texts[1].contains("目标：" + run.goal.objective))
        #expect(texts[1].contains("已用 1/30 个目标回合"))
        let continuationRequest = try #require(run.provider.requests().last)
        #expect(continuationRequest.last(where: { $0.role == .user })?.content.contains(run.goal.objective) == true)

        // Same admission as a user send: same session, mode and frozen policy.
        let continuation = try #require(run.chat.lastComposerSubmissionSnapshot)
        #expect(continuation.sessionID == userSnapshot.sessionID)
        #expect(continuation.turnID > userSnapshot.turnID)
        #expect(continuation.mode == mode && continuation.mode == userSnapshot.mode)
        #expect(continuation.approvalScope == userSnapshot.approvalScope)
        #expect(continuation.bypassModeConfirmed == userSnapshot.bypassModeConfirmed)
        #expect(continuation.policyRevision == userSnapshot.policyRevision)
        // Every admitted top-level task, a user send included, gets its own
        // task-unique grant epoch from the same task policy.
        #expect(continuation.grantEpoch.hasPrefix("composer-epoch:"))
        #expect(userSnapshot.grantEpoch.hasPrefix("composer-epoch:"))
        #expect(continuation.grantEpoch != userSnapshot.grantEpoch)
        #expect(continuation.workspaceID == userSnapshot.workspaceID)
        #expect(continuation.explicitlySelectedInteractiveAutoMode
            == userSnapshot.explicitlySelectedInteractiveAutoMode)

        let saved = try storedGoal(run)
        #expect(saved.id == run.goal.id)
        #expect(saved.status == .paused)
        #expect(saved.turnPauseReason == .emptyTurn)
        #expect(saved.budget.usedTurns == 2)
        #expect(run.chat.conversationGoalSidebarStatuses[run.sessionID] == .paused)
        let continuationOperation = "chat:" + continuation.sessionID + ":" + String(continuation.turnID)
            + ":" + continuation.messageID
        #expect(!notices.ids.contains(continuationOperation))
        #expect(notices.goalIDs.isEmpty)
    }

    @Test func switchedOffGoalDoesNotContinue() async throws {
        let run = try goalRun()
        defer { run.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: run.root) }
        let off = try run.chat.setConversationGoalAutoContinue(sessionID: run.sessionID, goalID: run.goal.id,
                                                               enabled: false)
        #expect(!off.autoContinueEnabled)
        _ = try sendUserGoalTurn(run)
        try await waitForGoalQuiet(run)
        #expect(run.provider.requests().count == 2)
        #expect(userTexts(run) == ["开始推进目标"])
        let saved = try storedGoal(run)
        #expect(saved.status == .active && !saved.autoContinueEnabled && saved.budget.usedTurns == 1)
    }

    @Test(arguments: [SessionStore.ConversationGoalControl.pause, .stop])
    func goalPausedOrStoppedDuringTurnDoesNotContinue(action: SessionStore.ConversationGoalControl) async throws {
        let run = try goalRun()
        defer { run.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: run.root) }
        _ = try sendUserGoalTurn(run, delays: [.milliseconds(300)])
        try await waitUntil { run.provider.requests().count == 1 }
        _ = try run.chat.controlConversationGoal(sessionID: run.sessionID, goalID: run.goal.id, action: action)
        try await waitForGoalQuiet(run)
        #expect(run.provider.requests().count == 2)
        #expect(userTexts(run) == ["开始推进目标"])
        #expect(try storedGoal(run).status == (action == .pause ? .paused : .stopped))
    }

    @Test func reviewedCompletionAndExhaustedBudgetDoNotContinueAndNotifyOnce() async throws {
        let completedRun = try goalRun()
        defer { completedRun.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: completedRun.root) }
        let completedNotices = GoalNoticeLog()
        completedRun.chat.onResponseNotification = { _, id, failed in completedNotices.record(id, failed: failed) }
        let reviewer = Policy599GoalReviewer()
        let snapshot = try ProviderRuntimeSnapshot(
            providerID: reviewer.name, modelID: reviewer.model.id,
            readinessEvidenceID: "goal-continuation-review-evidence",
            applyReceiptID: "provider-readiness-apply:goal-continuation-review")
        completedRun.chat.prepareGoalReviewPrimary = { _ in (snapshot, reviewer) }
        _ = try sendUserGoalTurn(completedRun, replies: [call("goal-done", "goal_update",
            ["action": "complete", "evidence": ["Marker": "Marker file checked"]])])
        try await waitUntil {
            completedRun.chat.sessionStore?.loadSession(id: completedRun.sessionID.uuidString)?.goal?.status == .completed
        }
        try await waitForGoalQuiet(completedRun)
        #expect(try storedGoal(completedRun).status == .completed)
        #expect(completedRun.provider.requests().count == 2)
        #expect(userTexts(completedRun) == ["开始推进目标"])
        #expect(completedNotices.goalIDs == ["goal:" + completedRun.goal.id.uuidString + ":completed"])
        #expect(completedNotices.successIDs.contains("goal:" + completedRun.goal.id.uuidString + ":completed"))

        let budgetRun = try goalRun()
        defer { budgetRun.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: budgetRun.root) }
        let budgetNotices = GoalNoticeLog()
        budgetRun.chat.onResponseNotification = { _, id, failed in budgetNotices.record(id, failed: failed) }
        _ = try #require(budgetRun.chat.sessionStore).setConversationGoalBudget(
            sessionID: budgetRun.sessionID, goalID: budgetRun.goal.id, turns: 1, tokens: nil, durationSeconds: nil)
        _ = try sendUserGoalTurn(budgetRun)
        try await waitForGoalQuiet(budgetRun)
        #expect(budgetRun.provider.requests().count == 2)
        let exhausted = try storedGoal(budgetRun)
        #expect(exhausted.status == .paused && exhausted.budgetPauseReason == .turns)
        #expect(budgetNotices.goalIDs == ["goal:" + budgetRun.goal.id.uuidString + ":budget"])
    }

    @Test func queuedUserMessageIsSentBeforeTheContinuation() async throws {
        let run = try goalRun()
        defer { run.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: run.root) }
        _ = try sendUserGoalTurn(run, delays: [.milliseconds(300)])
        try await waitUntil { run.provider.requests().count == 1 }
        run.chat.draftText = "排队的用户消息"
        try #require(run.chat.enqueueComposer())
        try await waitForGoalQuiet(run)
        let texts = userTexts(run)
        try #require(texts.count == 3)
        #expect(texts[0] == "开始推进目标")
        #expect(texts[1] == "排队的用户消息")
        #expect(texts[2].hasPrefix("〔目标续跑〕"))
        #expect(try storedGoal(run).turnPauseReason == .emptyTurn)
    }

    @Test func unsentDraftHoldsTheContinuation() async throws {
        let run = try goalRun()
        defer { run.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: run.root) }
        _ = try sendUserGoalTurn(run, delays: [.milliseconds(300)])
        try await waitUntil { run.provider.requests().count == 1 }
        run.chat.draftText = "用户还没发出的草稿"
        try await waitUntil { !run.chat.isStreaming }
        try await Task.sleep(for: .milliseconds(200))
        #expect(run.provider.requests().count == 2)
        #expect(run.chat.draftText == "用户还没发出的草稿")
        #expect(userTexts(run) == ["开始推进目标"])
        #expect(run.chat.pendingGoalContinuationSessions.contains(run.sessionID))
        #expect(try storedGoal(run).status == .active)
    }

    @Test(arguments: [ApprovalDecisionStatus.expired, .denied])
    func expiredApprovalRecordsGoalToDoButDenialDoesNot(status: ApprovalDecisionStatus) async throws {
        let approval = GoalContinuationApproval(status: status)
        let run = try goalRun(approval: approval)
        defer { run.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: run.root) }
        _ = try sendUserGoalTurn(run)
        try await waitForGoalQuiet(run)
        #expect(await approval.requests.map(\.callID) == ["goal-write"])
        #expect(!FileManager.default.fileExists(atPath: run.root.appendingPathComponent("goal-marker.txt").path))
        let saved = try storedGoal(run)
        if status == .expired {
            #expect(saved.blockers.map(\.summary) == ["审批已过期：file_write"])
            #expect(userTexts(run).last?.contains("待用户处理 1 项：审批已过期：file_write") == true)
        } else {
            #expect(saved.blockers.isEmpty)
        }
        // The refused call still makes the user turn non-empty, so it continued once.
        #expect(userTexts(run).count == 2)
        #expect(saved.turnPauseReason == .emptyTurn)
    }

    @Test func startingResumingAndSwitchingOnAnIdleGoalContinueAtOnce() async throws {
        let run = try goalRun()
        defer { run.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: run.root) }
        // New goal on an idle session: the first continuation starts by itself.
        try await waitForGoalQuiet(run)
        #expect(run.provider.requests().count == 1)
        #expect(userTexts(run).count == 1)
        #expect(userTexts(run).first?.contains("已用 0/30 个目标回合") == true)
        #expect(try storedGoal(run).turnPauseReason == .emptyTurn)

        _ = try run.chat.controlConversationGoal(sessionID: run.sessionID, goalID: run.goal.id, action: .resume)
        try await waitForGoalQuiet(run)
        #expect(run.provider.requests().count == 2)

        _ = try run.chat.setConversationGoalAutoContinue(sessionID: run.sessionID, goalID: run.goal.id, enabled: false)
        _ = try run.chat.controlConversationGoal(sessionID: run.sessionID, goalID: run.goal.id, action: .resume)
        try await waitForGoalQuiet(run)
        #expect(run.provider.requests().count == 2)
        _ = try run.chat.setConversationGoalAutoContinue(sessionID: run.sessionID, goalID: run.goal.id, enabled: true)
        try await waitForGoalQuiet(run)
        #expect(run.provider.requests().count == 3)
        #expect(userTexts(run).count == 3)
        #expect(userTexts(run).allSatisfy { $0.hasPrefix("〔目标续跑〕") })
    }

    @Test func goalStartedWithAnUnsentDraftOnlyWaits() async throws {
        let run = try goalRun()
        defer { run.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: run.root) }
        _ = try run.chat.controlConversationGoal(sessionID: run.sessionID, goalID: run.goal.id, action: .stop)
        run.chat.draftText = "用户的草稿"
        let next = try run.chat.startConversationGoal(sessionID: run.sessionID, objective: "Second goal")
        try await Task.sleep(for: .milliseconds(300))
        #expect(run.provider.requests().isEmpty)
        #expect(run.chat.draftText == "用户的草稿")
        #expect(run.chat.pendingGoalContinuationSessions.contains(run.sessionID))
        let saved = try storedGoal(run)
        #expect(saved.id == next.id)
        #expect(saved.status == .active)
    }

    @Test func planModeGoalIsSetWithNoticeAndNeverContinues() async throws {
        let run = try goalRun(mode: .plan)
        defer { run.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: run.root) }
        #expect(run.chat.pastedTextActionFeedback == ChatStore.planModeGoalNotice)
        try await waitForGoalQuiet(run)
        #expect(run.provider.requests().isEmpty)
        #expect(try storedGoal(run).status == .active)
    }

    @Test func newGoalSetDuringARunningTurnContinuesAfterThatTurnEnds() async throws {
        let run = try goalRun()
        defer { run.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: run.root) }
        _ = try sendUserGoalTurn(run, delays: [.milliseconds(300)])
        try await waitUntil { run.provider.requests().count == 1 }
        _ = try run.chat.controlConversationGoal(sessionID: run.sessionID, goalID: run.goal.id, action: .stop)
        let next = try run.chat.startConversationGoal(sessionID: run.sessionID, objective: "Second goal set mid-turn")
        try await waitForGoalQuiet(run)
        // The old turn's goal no longer matches; it must not drop the new goal's continuation.
        #expect(run.provider.requests().count == 3)
        let texts = userTexts(run)
        try #require(texts.count == 2)
        #expect(texts[1].contains("目标：Second goal set mid-turn"))
        let saved = try storedGoal(run)
        #expect(saved.id == next.id)
        #expect(saved.turnPauseReason == .emptyTurn)
    }

    @Test func continuationRefusedAfterItTookTheComposerRemovesOnlyItsText() async throws {
        let run = try goalRun()
        defer { run.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: run.root) }
        // The goal was just set on an idle session, so its continuation is about
        // to borrow the Composer. Input arrives while that send is being
        // admitted, and the admission refuses it.
        // The settings transaction fence (no effective settings) refuses it.
        let chat = run.chat
        chat.effectiveSettingsSnapshotSource = { [weak chat] in
            if let chat, !chat.draftText.hasSuffix("用户刚输入的") { chat.draftText += "用户刚输入的" }
            return nil
        }
        try await waitUntil { chat.draftText == "用户刚输入的" }
        try await Task.sleep(for: .milliseconds(200))
        #expect(chat.lastSubmissionBlockedByInvalidSettings)
        #expect(chat.draftText == "用户刚输入的")
        #expect(userTexts(run).isEmpty)
        #expect(run.provider.requests().isEmpty)
        #expect(chat.pendingGoalContinuationSessions.contains(run.sessionID))
    }

    @Test func stopWhileTheContinuationIsBeingAdmittedDropsItForGood() async throws {
        let run = try goalRun()
        defer { run.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: run.root) }
        // The user presses Stop while the continuation's send is still being
        // admitted; the admission then refuses it and its callback arrives last.
        // The settings transaction fence (no effective settings) refuses it.
        let chat = run.chat
        chat.effectiveSettingsSnapshotSource = { [weak chat] in
            chat?.stopStreaming()
            return nil
        }
        try await waitUntil { chat.lastSubmissionBlockedByInvalidSettings }
        try await Task.sleep(for: .milliseconds(300))
        #expect(chat.lastSubmissionBlockedByInvalidSettings)
        #expect(!chat.pendingGoalContinuationSessions.contains(run.sessionID))
        #expect(chat.draftText.isEmpty)
        #expect(userTexts(run).isEmpty)
        #expect(run.provider.requests().isEmpty)
    }

    @Test func userDenialInsideAContinuationPausesTheGoal() async throws {
        let approval = GoalContinuationApproval(statuses: [.approved, .denied])
        let run = try goalRun(approval: approval)
        defer { run.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: run.root) }
        let second = run.root.appendingPathComponent("second-marker.txt")
        _ = try sendUserGoalTurn(run, replies: [
            call("goal-write", "file_write", ["path": run.root.appendingPathComponent("goal-marker.txt").path,
                                              "content": "marker"]),
            "第一回合完成。",
            call("goal-write-2", "file_write", ["path": second.path, "content": "second"])
        ])
        try await waitForGoalQuiet(run)
        #expect(await approval.requests.map(\.callID) == ["goal-write", "goal-write-2"])
        #expect(!FileManager.default.fileExists(atPath: second.path))
        // User turn (2 requests) + one continuation (2 requests); no second continuation.
        #expect(run.provider.requests().count == 4)
        #expect(userTexts(run).count == 2)
        let saved = try storedGoal(run)
        #expect(saved.status == .paused)
        #expect(saved.turnPauseReason == .approvalDenied)
    }

    @Test func switchingAutoContinueDuringATurnStillLetsStopPauseTheGoal() async throws {
        let run = try goalRun()
        defer { run.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: run.root) }
        _ = try sendUserGoalTurn(run, delays: [.seconds(30)])
        try await waitUntil { run.provider.requests().count == 1 }
        _ = try run.chat.setConversationGoalAutoContinue(sessionID: run.sessionID, goalID: run.goal.id, enabled: false)
        run.chat.stopStreaming()
        let saved = try storedGoal(run)
        #expect(saved.status == .paused)
        #expect(saved.turnPauseReason == .cancelled)
        #expect(!saved.autoContinueEnabled)
    }

    @Test func backgroundGoalSessionWaitsVisiblyThenContinuesWhenFocused() async throws {
        let run = try goalRun()
        defer { run.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: run.root) }
        _ = try sendUserGoalTurn(run, delays: [.milliseconds(300)])
        try await waitUntil { run.provider.requests().count == 1 }
        run.chat.newSession()
        let other = try #require(run.chat.activeSessionID)
        try #require(other != run.sessionID)
        // The goal turn finishes in the background, then waits visibly.
        try await waitUntil {
            !run.chat.isStreaming
                && run.chat.conversationGoalSidebarStatuses[run.sessionID] == .awaitingContinuation
        }
        #expect(run.chat.conversationGoalSidebarStatuses[run.sessionID] == .awaitingContinuation)
        #expect(run.chat.pendingGoalContinuationSessions.contains(run.sessionID))
        #expect(run.provider.requests().count == 2)
        #expect(run.chat.messages(forSession: other)?.contains { $0.role == .user } != true)

        try #require(run.chat.applySwitchSession(id: run.sessionID))
        try await waitForGoalQuiet(run)
        #expect(run.provider.requests().count == 3)
        #expect(userTexts(run).last?.hasPrefix("〔目标续跑〕") == true)
        #expect(try storedGoal(run).budget.usedTurns == 2)
        #expect(run.chat.messages(forSession: other)?.contains { $0.role == .user } != true)
    }

    @Test func continuationPromptKeepsFullGoalAndChecksCurrentProgressFirst() throws {
        let goal = try #require(ConversationGoalState(
            sessionID: UUID(), objective: "核对报告的摘要、数据表和附录"))
        let prompt = ChatStore.goalContinuationPrompt(for: goal)
        #expect(prompt.contains("目标：核对报告的摘要、数据表和附录"))
        #expect(prompt.contains("不缩小原目标范围"))
        #expect(prompt.contains("以当前状态为准"))
        #expect(prompt.contains("先判断上回合是否有进展"))
        let progress = try #require(prompt.range(of: "先判断上回合是否有进展"))
        let remaining = try #require(prompt.range(of: "请先推进仍可做的部分"))
        #expect(progress.lowerBound < remaining.lowerBound)
    }

    @Test("续跑提示带上次复核的驳回理由")
    func continuationPromptCarriesTheRejectedReviewReason() throws {
        var goal = try #require(ConversationGoalState(sessionID: UUID(), objective: "写一个合成文件"))
        let reported = goal.reportCompletion(evidence: ["path: a.txt"])
        let reviewID = try #require(reported)
        let recorded = goal.recordReview(id: reviewID, result: .init(outcome: .rejected, reason: "没有读到文件内容"))
        #expect(recorded)
        let prompt = ChatStore.goalContinuationPrompt(for: goal)
        #expect(prompt.contains("上次完成报告未通过独立复核，复核意见：没有读到文件内容"))
        #expect(prompt.contains("已用 0/30 个目标回合"))
    }

    @Test("目标栏复核供应商只显示安全名称")
    func goalBarReviewProviderShowsSafeLabel() {
        let routeIdentity = "MINISCANVAS_JOURNEY_DEEPSEEK_API_KEY"
        let shown = GlobalComposerView.goalReviewProviderText(routeIdentity)
        #expect(shown == "自定义")
        #expect(!shown.contains(routeIdentity))
        #expect(GlobalComposerView.goalReviewProviderText("Mock") == "演示模式")
        var deepSeek = EnvVarEntry(name: "synthetic-deepseek-route", value: "", isSecret: true)
        deepSeek.displayName = " " + deepSeek.name + " "
        #expect(GlobalComposerView.goalReviewProviderText(deepSeek.name, records: [deepSeek]) == "自定义")
        deepSeek.baseURL = "https://api.deepseek.com"
        #expect(GlobalComposerView.goalReviewProviderText(deepSeek.name, records: [deepSeek]) == ProviderType.deepSeek.displayName)
        deepSeek.displayName = "团队模型"
        #expect(GlobalComposerView.goalReviewProviderText(deepSeek.name, records: [deepSeek]) == "团队模型")
    }
}

// D2-14：/goal 经发送按钮与回车同一入口；不带参数时显示当前目标。
extension Policy599ProductionConsumerTests {
    @Test func goalCommandThroughSendButtonSetsAndShowsTheGoal() async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        let chat = fixture.bridge.chat
        defer { chat.stopAllStreamingForSafety(); withExtendedLifetime(fixture) {} }
        let id = try #require(chat.activeSessionID)
        // 与 App 组装根一致：生产注册表含 /goal。
        #expect(chat.installComposerCommandRegistry(AppCommandCatalog.assembled(bridge: fixture.bridge).registry))

        func submit(_ text: String) async throws {
            chat.draftText = text
            chat.sendDraft()
            for _ in 0..<300 where !chat.draftText.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        try await submit("/goal")
        #expect(chat.pastedTextActionFeedback == "当前会话还没有目标。输入 /goal 加目标内容来设定。")
        #expect(chat.conversationGoal(for: id) == nil)

        try await submit("/goal 整理本周报告")
        let goal = try #require(chat.conversationGoal(for: id))
        #expect(goal.objective == "整理本周报告")
        _ = try chat.setConversationGoalAutoContinue(sessionID: id, goalID: goal.id, enabled: false)
        chat.stopAllStreamingForSafety()

        try await submit("/goal")
        #expect(chat.pastedTextActionFeedback == "当前目标：整理本周报告")
        #expect(chat.conversationGoal(for: id)?.objective == "整理本周报告")
    }
}


// MARK: - Goal review is not cancelled by unrelated operations (B2-16)

extension Policy599ProductionConsumerTests {
    private func installGoalReviewer(_ run: GoalRun, _ reviewer: Policy599GoalReviewer) throws {
        let snapshot = try ProviderRuntimeSnapshot(
            providerID: reviewer.name, modelID: reviewer.model.id,
            readinessEvidenceID: "goal-review-cancel-evidence",
            applyReceiptID: "provider-readiness-apply:goal-review-cancel")
        run.chat.prepareGoalReviewPrimary = { _ in (snapshot, reviewer) }
    }

    private func completeGoalReply() throws -> String {
        try call("goal-done", "goal_update", ["action": "complete", "evidence": ["Marker": "Marker file checked"]])
    }

    /// The goal's first review is running, then the session is left and the review is cancelled.
    private func cancelReviewBySwitchingAway(_ run: GoalRun, _ reviewer: Policy599GoalReviewer) async throws {
        try installGoalReviewer(run, reviewer)
        _ = try sendUserGoalTurn(run, replies: [completeGoalReply()])
        try await waitUntil { reviewer.counts.text == 1 }
        try #require(reviewer.counts.text == 1)
        run.chat.newSession()
        let other = try #require(run.chat.activeSessionID)
        try #require(other != run.sessionID)
        try await waitUntil { (try? self.storedGoal(run).lastReview) != nil }
        try #require(try storedGoal(run).lastReview?.outcome == .cancelled)
    }

    @Test func queuedMessageSentAtTurnEndDoesNotCancelTheGoalReview() async throws {
        let run = try goalRun()
        defer { run.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: run.root) }
        let notices = GoalNoticeLog()
        run.chat.onResponseNotification = { _, id, failed in notices.record(id, failed: failed) }
        let reviewer = Policy599GoalReviewer(passes: true, delay: .milliseconds(800))
        try installGoalReviewer(run, reviewer)
        _ = try sendUserGoalTurn(run, replies: [completeGoalReply()], delays: [.milliseconds(300)])
        try await waitUntil { run.provider.requests().count == 1 }
        run.chat.draftText = "排队的用户消息"
        try #require(run.chat.enqueueComposer())
        // The queued message goes out right after the turn ends, while the review is still running.
        try await waitUntil { self.userTexts(run).contains("排队的用户消息") }
        try await waitUntil { (try? self.storedGoal(run).lastReview) != nil }
        let saved = try storedGoal(run)
        #expect(saved.lastReview?.outcome == .passed)
        #expect(saved.status == .completed)
        #expect(reviewer.counts.text == 1)
        #expect(userTexts(run).contains("排队的用户消息"))
        #expect(notices.goalIDs == ["goal:" + run.goal.id.uuidString + ":completed"])
    }

    @Test func switchingAwayCancelsReviewNotifiesOnceAndFocusRetriesExactlyOnce() async throws {
        let run = try goalRun()
        defer { run.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: run.root) }
        let notices = GoalNoticeLog()
        run.chat.onResponseNotification = { _, id, failed in notices.record(id, failed: failed) }
        let reviewer = Policy599GoalReviewer(passes: true, delay: .seconds(30))
        try await cancelReviewBySwitchingAway(run, reviewer)

        let cancelled = try storedGoal(run)
        #expect(cancelled.id == run.goal.id)
        #expect(cancelled.status == .active)
        #expect(cancelled.lastReview?.outcome == .cancelled)
        #expect(cancelled.lastReview?.turnsAtReview == 1 && cancelled.budget.usedTurns == 1)
        #expect(cancelled.reviewNeedsAttention)
        let key = "goal:" + run.goal.id.uuidString + ":reviewCancelled:1"
        #expect(notices.goalIDs == [key])
        #expect(!notices.successIDs.contains(key))
        // Still in the background: no continuation has started.
        #expect(run.provider.requests().count == 2)
        #expect(reviewer.counts.text == 1)

        // Back in the foreground and idle: exactly one continuation with the cancelled-review hint.
        try #require(run.chat.applySwitchSession(id: run.sessionID))
        try await waitForGoalQuiet(run)
        #expect(run.provider.requests().count == 3)
        let texts = userTexts(run)
        try #require(texts.count == 2)
        #expect(texts[1].hasPrefix("〔目标续跑〕"))
        #expect(texts[1].contains("上次独立复核被中断（会话已切走或模型已切换），请确认完成证据后重新提交完成报告"))
        let retried = try storedGoal(run)
        #expect(retried.budget.usedTurns == 2)
        // The turn count moved on, so the old cancellation no longer needs attention.
        #expect(retried.lastReview?.turnsAtReview == 1)
        #expect(!retried.reviewNeedsAttention)

        // Leaving and returning again does not trigger a second retry.
        run.chat.newSession()
        try #require(run.chat.applySwitchSession(id: run.sessionID))
        try await waitForGoalQuiet(run)
        try await Task.sleep(for: .milliseconds(200))
        #expect(run.provider.requests().count == 3)
        #expect(userTexts(run).count == 2)
        #expect(try storedGoal(run).budget.usedTurns == 2)
        #expect(notices.goalIDs == [key])
    }

    @Test func goalStoppedByTheUserAfterACancelledReviewIsNotRetried() async throws {
        let run = try goalRun()
        defer { run.chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: run.root) }
        let reviewer = Policy599GoalReviewer(passes: true, delay: .seconds(30))
        try await cancelReviewBySwitchingAway(run, reviewer)
        _ = try #require(run.chat.sessionStore).controlConversationGoal(
            sessionID: run.sessionID, goalID: run.goal.id, action: .stop)

        try #require(run.chat.applySwitchSession(id: run.sessionID))
        try await waitForGoalQuiet(run)
        try await Task.sleep(for: .milliseconds(300))
        #expect(run.provider.requests().count == 2)
        #expect(userTexts(run) == ["开始推进目标"])
        let saved = try storedGoal(run)
        #expect(saved.status == .stopped)
        #expect(saved.budget.usedTurns == 1)
    }

    @Test("续跑提示在上次复核被中断时要求重新提交完成报告")
    func continuationPromptAsksToResubmitAfterACancelledReview() throws {
        var goal = try #require(ConversationGoalState(sessionID: UUID(), objective: "写一个合成文件"))
        let reported = goal.reportCompletion(evidence: ["path: a.txt"])
        let reviewID = try #require(reported)
        let recorded = goal.recordReview(id: reviewID, result: .init(outcome: .cancelled))
        #expect(recorded)
        #expect(goal.status == .active)
        let prompt = ChatStore.goalContinuationPrompt(for: goal)
        #expect(prompt.contains("上次独立复核被中断（会话已切走或模型已切换），请确认完成证据后重新提交完成报告"))
        #expect(!prompt.contains("未通过独立复核"))
    }
}

// 0703/0831：无项目会话里"请记住…"不得静默失败，也不得让模型声称已记住。
extension Policy599ProductionConsumerTests {
    @Test func rememberRequestInAnUnassignedSessionSaysItWasNotSaved() async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        let bridge = fixture.bridge
        defer { bridge.chat.stopAllStreamingForSafety(); withExtendedLifetime(fixture) {} }
        try fixture.settings.provisionBuiltInMemoryCandidateSubmissions()

        _ = try await submit(bridge, provider, replies: ["好的。"], mode: .manual,
                             requiresFinalProviderRequest: false,
                             interactive: true, draft: "请记住：我偏好简洁的中文回答。")

        let expected = "当前会话未归入项目，这条没有保存为记忆。可先把会话归入项目再说一次，或在 设置 › 记忆 编辑全局记忆。"
        #expect(bridge.chat.pastedTextActionFeedback == expected)
        let prompt = try #require(provider.lastPrompt())
        #expect(prompt.contains("本回合用户要求记住的内容没有被保存"))
        #expect(prompt.contains("不要声称已经记住"))
        #expect(try fixture.settings.pendingMemoryProposals().isEmpty)
        #expect(try fixture.settings.memoryStore.activeFacts().isEmpty)
    }
}

// 第 7、8、9 项：所有档位可用对话记住、放宽说法、"忘掉…"本地打开记忆检索。
extension Policy599ProductionConsumerTests {
    /// 与 manualRememberOnlyStagesTheExactUserFact 相同的项目会话夹具。
    private func makeProjectMemoryFixture(root: URL, provider: Policy599Provider,
                                          approval: Policy599Approval) throws -> Policy599Fixture {
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        try fixture.settings.provisionBuiltInMemoryCandidateSubmissions()
        let bridge = fixture.bridge
        let sessionID = try #require(bridge.chat.activeSessionID)
        let handler = try #require(bridge.productionProjectSessionHandler)
        let project = root.appendingPathComponent("memory-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let projectID = try handler.authorizeFolderFromNativePicker(project)
        bridge.chat.setProject(ChatStore.SessionProject(id: projectID, name: "Synthetic project",
                                                       workingDirectory: project.path), forSession: sessionID)
        fixture.settings.memoryScopeProvider = { [weak chat = bridge.chat] in chat?.activeMemoryScope }
        let scope = MemoryScope(sessionID: sessionID.uuidString, projectID: projectID)
        try #require(bridge.chat.activeMemoryScope == scope)
        try #require(bridge.chat.trustedProjectRootProvider?(scope) != nil)
        return fixture
    }

    @Test(.serialized, arguments: ["remember", "fromNowOn"])
    func rememberInAutoEditStagesPendingFactForApproval(scenario: String) async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeProjectMemoryFixture(root: root, provider: provider, approval: approval)
        let bridge = fixture.bridge
        defer { bridge.chat.stopAllStreamingForSafety(); withExtendedLifetime(fixture) {} }
        // "请记住：…"剥前缀；"以后都…"整句就是事实。
        let fact = scenario == "remember" ? "草稿标题是蓝色花园。" : "以后都用中文回答"
        let draft = scenario == "remember" ? "请记住：" + fact : fact
        let response = try call("rememberAuto599", "memory_propose_fact", ["fact": fact])
        _ = try await submit(bridge, provider, replies: [response], mode: .autoEdit,
                             requiresFinalProviderRequest: false, interactive: true, draft: draft)
        #expect(bridge.chat.lastComposerSubmissionSnapshot?.mode == .autoEdit)
        let facts = try #require((bridge.chat.agentEngine as? AgentLoopChatEngine)?.toolExecutionFactLedger.facts)
        #expect(facts.contains {
            $0.toolName == "memory_propose_fact" && $0.toolCallID == "rememberAuto599" && $0.status == .succeeded
        })
        // 只进入设置里的待审，未经批准不生效。
        let pending = try fixture.settings.pendingMemoryProposals()
        #expect(pending.map(\.text) == [fact])
        #expect(try fixture.settings.memoryStore.activeFacts().isEmpty)
    }

    @Test func forgetRequestOpensMemorySearchLocallyWithoutAModelRequest() async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        let bridge = fixture.bridge
        defer { bridge.chat.stopAllStreamingForSafety(); withExtendedLifetime(fixture) {} }
        var openedPages: [String?] = []
        bridge.deepLinkHandler.onOpenSettings = { openedPages.append($0) }
        let requestsBefore = provider.requests().count
        let messagesBefore = bridge.chat.messages.count

        bridge.chat.composerPolicySelection = ComposerPolicySelection(mode: .autoEdit, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        bridge.chat.draftText = "忘掉 中文"
        bridge.chat.selectInteractiveComposerMode(.autoEdit)
        bridge.chat.submitInteractiveComposer()
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }

        #expect(!bridge.chat.isStreaming)
        #expect(provider.requests().count == requestsBefore)
        #expect(bridge.chat.messages.count == messagesBefore)
        #expect(bridge.chat.draftText.isEmpty)
        #expect(openedPages == ["记忆"])
        #expect(fixture.settings.pendingMemorySearchQuery == "中文")
        #expect(bridge.chat.pastedTextActionFeedback
            == "已打开 设置 › 记忆 并搜索「中文」，请在结果里删除要忘掉的条目。")
        #expect(try fixture.settings.pendingMemoryProposals().isEmpty)
    }
}

// 收紧识别：普通提问"忘记密码怎么办"照常发给模型，不打开记忆页。
extension Policy599ProductionConsumerTests {
    @Test func ordinaryQuestionAboutForgettingStillReachesTheModel() async throws {
        let root = try makeRoot(), provider = Policy599Provider(), approval = Policy599Approval(approvals: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBridge(root: root, provider: provider, approval: approval)
        let bridge = fixture.bridge
        defer { bridge.chat.stopAllStreamingForSafety(); withExtendedLifetime(fixture) {} }
        var openedPages: [String?] = []
        bridge.deepLinkHandler.onOpenSettings = { openedPages.append($0) }
        _ = try await submit(bridge, provider, replies: ["可以在登录页点“忘记密码”。"], mode: .manual,
                             requiresFinalProviderRequest: false, interactive: true, draft: "忘记密码怎么办")
        #expect(provider.requests().count >= 1)
        #expect(openedPages.isEmpty)
        #expect(fixture.settings.pendingMemorySearchQuery == nil)
    }
}
