import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

@Suite("installed manual compaction and ordinary continuation", .serialized)
@MainActor
struct ContextBoundary0715Tests {
    @Test("right-panel shared action retains its installed production engine across compact, send and reopen")
    func installedManualEntryFeedsOrdinaryRequestAndFreshReopen() async throws {
        let fixture = try Fixture()
        let bridge = try fixture.makeBridge(sessions: fixture.settings.sessionStore)
        let chat = bridge.chat
        defer { chat.stopAllStreamingForSafety(); withExtendedLifetime(fixture.settings) {} }
        await fixture.attach(bridge)
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        let installed = try #require(chat.agentEngine as? AgentLoopChatEngine)
        #expect(chat.turnRuntimeSnapshotFactory != nil)
        #expect(chat.prepareTopLevelTaskPolicy != nil)
        let source = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        let ledger = installed.toolExecutionFactLedger
        let identity = AgentExecutionIdentity(turn: .init(sessionID: source.id,
            turnID: 1, messageID: "owned-historical0715"), operationID: "owned-read0715", attempt: 1)
        let receipt = try ledger.mint(toolCallID: "completed-read0715", toolName: "file_read",
            attemptID: "owned-read-attempt0715", attemptNumber: 1, executionIdentity: identity)
        _ = try ledger.settle(receipt, status: .succeeded)
        let facts = ledger.facts
        #expect(facts.count == 1)

        let summary = Provider(summary: true)
        let dialogue = Provider(summary: false)
        chat.compactionProviderOverride = summary
        chat.streamingProviderOverride = dialogue
        chat.composerPolicySelection = .init(mode: .plan, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        // ContextPanelView calls this exact shared production action. This is
        // an installed host consumer, not a claim of an actual native click.
        chat.compactContext()
        let committed = await waitUntil {
            (try? fixture.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: source.id)) != nil
        }
        #expect(committed, "installed manual compaction did not produce its canonical checkpoint")
        let checkpoint = try #require(try fixture.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: source.id))
        #expect(summary.requests.count == 1 && dialogue.requests.isEmpty)
        let summaryInput = try #require(summary.requests.first?.first)
        #expect(summary.requests.first?.count == 1 && summaryInput.role == .user)
        #expect(summaryInput.content.contains("===== 对话记录 ====="))
        #expect(summaryInput.content.contains("For option 0, also compare dependency 4."))
        #expect(summaryInput.content.contains("Keep the original title. Earlier authorization was read-only."))
        let recent = Array(source.messages.suffix(3))
        for message in recent {
            #expect(!summaryInput.content.contains(message.content))
        }
        #expect(checkpoint.schemaVersion == CompactionCheckpoint.lossySummarySchemaVersion)
        #expect(checkpoint.sourceTranscriptRevision == source.transcriptRevision)
        let committedSource = try #require(fixture.settings.sessionStore.loadSession(id: source.id))
        #expect(checkpoint.resultTranscriptRevision == source.transcriptRevision + 1)
        #expect(committedSource.updatedAt >= source.updatedAt)
        // A durable checkpoint advances its revision/time while leaving every
        // canonical field and message intact; it does not replace the transcript.
        var expectedCommittedSource = source
        expectedCommittedSource.transcriptRevision = checkpoint.resultTranscriptRevision
        expectedCommittedSource.updatedAt = committedSource.updatedAt
        #expect(committedSource == expectedCommittedSource)
        #expect(committedSource.messages == source.messages)
        #expect(ledger.facts == facts)
        let projection = try ChatSessionBridge.resumeCanonicalMessages(
            sessionStore: fixture.settings.sessionStore, sessionID: source.id,
            taskStore: bridge.agentTaskStore, effectLedger: ledger)
        #expect(projection == checkpoint.replacementHistory)
        #expect(Compactor.hasMaterialRequestReduction(from: source.messages, to: projection))
        let summaryMessage = try #require(projection.first)
        #expect(summaryMessage.role == .user)
        #expect(summaryMessage.content.hasPrefix("<context-summary>"))
        #expect(summaryMessage.content.contains(Provider.summaryConstraint))
        #expect(Array(projection.suffix(3)) == recent)
        #expect(projection.contains { $0.content.contains(facts[0].receiptID) })

        let next = "Continue the comparison after the right-panel action; keep the original title and do not write files."
        chat.draftText = next
        chat.submitComposer()
        let admitted = try #require(chat.lastComposerSubmissionSnapshot)
        let task = try #require(chat.turnTaskForTests(sessionID: fixture.sessionID))
        await task.value
        #expect(!chat.hasStreamingTasksForSafety)
        #expect(chat.activeSessionID == fixture.sessionID)
        #expect(chat.agentEngine is AgentLoopChatEngine)
        #expect(summary.requests.count == 1 && dialogue.requests.count == 1)
        let sent = try #require(dialogue.requests.first)
        #expect(sent == projection + [LLMMessage(role: .user, content: next)])
        #expect(sent.filter { $0.role == .user && $0.content == next }.count == 1)
        #expect(Array(sent.dropLast().suffix(3)) == recent)
        #expect(ledger.facts == facts, "retained completed receipt is context, not an instruction to redispatch")
        let canonical = try #require(fixture.settings.sessionStore.loadSession(id: source.id))
        #expect(canonical.messages.starts(with: source.messages))
        #expect(canonical.messages.filter { $0.role == .user && $0.content == next }.count == 1)
        #expect(canonical.messages.count == source.messages.count + 2)
        #expect(try fixture.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: source.id) == checkpoint)

        let sessions = SessionStore(directory: fixture.profile.sessionDirectory)
        #expect(sessions.loadSession(id: source.id) == canonical)
        let reopened = try fixture.makeBridge(sessions: sessions)
        defer { reopened.chat.stopAllStreamingForSafety(); withExtendedLifetime(reopened) {} }
        await fixture.attach(reopened)
        #expect(reopened.chat.applySwitchSession(id: fixture.sessionID))
        let reopenedEngine = try #require(reopened.chat.agentEngine as? AgentLoopChatEngine)
        #expect(reopenedEngine.toolExecutionFactLedger.facts == facts)
        let reopenedProjection = try ChatSessionBridge.resumeCanonicalMessages(sessionStore: sessions,
            sessionID: source.id, taskStore: reopened.agentTaskStore,
            effectLedger: reopenedEngine.toolExecutionFactLedger)
        #expect(reopenedProjection.starts(with: projection))
        #expect(Array(reopenedProjection.suffix(2)) == Array(canonical.messages.suffix(2)))
        let freshDialogue = Provider(summary: false)
        reopened.chat.streamingProviderOverride = freshDialogue
        reopened.chat.compactionProviderOverride = summary
        reopened.chat.composerPolicySelection = .init(mode: .plan, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        let afterReopen = "Continue after reopening this exact persistent conversation."
        reopened.chat.draftText = afterReopen
        reopened.chat.submitComposer()
        let freshAdmission = try #require(reopened.chat.lastComposerSubmissionSnapshot)
        #expect(freshAdmission.taskID != admitted.taskID)
        #expect(freshAdmission.messageID != admitted.messageID)
        let freshTask = try #require(reopened.chat.turnTaskForTests(sessionID: fixture.sessionID))
        await freshTask.value
        #expect(!reopened.chat.hasStreamingTasksForSafety)
        #expect(freshDialogue.requests == [reopenedProjection + [LLMMessage(role: .user, content: afterReopen)]])
        #expect(summary.requests.count == 1)
        #expect(reopenedEngine.toolExecutionFactLedger.facts == facts)
        #expect(try sessions.loadLatestCompactionCheckpoint(sessionID: source.id) == checkpoint)
    }

    @Test("installed web fetch reports private-address failure without undoing the approved card")
    func approvedWebFetchPrivateAddressReachesModelAndKeepsOriginalCard() async throws {
        let fixture = try Fixture(longHistory: false)
        let bridge = try fixture.makeBridge(sessions: fixture.settings.sessionStore)
        let chat = bridge.chat
        defer { chat.stopAllStreamingForSafety(); withExtendedLifetime(fixture.settings) {} }

        bridge.webFetchNetworkConfigurationProvider = { [settings = fixture.settings] defaults in
            settings.networkDomainConfigurationSnapshot(expectedDefaults: defaults)
        }
        bridge.webFetchPinnedRouteProvider = { _ in .directConfirmed }
        await fixture.attach(bridge)
        try #require(bridge.webFetchUsesPinnedApproval)
        try #require(chat.applySwitchSession(id: fixture.sessionID))
        let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        let ledger = engine.toolExecutionFactLedger
        try #require(ledger.hasDurableAuthority)
        let consumer = try await chat.awaitApprovalRecovery()
        let rules = chat.composerGrantStore.persistentRules
        let beforeRules = rules.allRules()
        let target = "https://127.0.0.1/e16-private"
        let calls = ["e16-private-first", "e16-private-retry"].map { id in
            LLMToolCall(id: id, name: WebFetchToolContract.toolName,
                rawArguments: #"{"url":"https://127.0.0.1/e16-private"}"#,
                arguments: ["url": target])
        }
        let provider = Provider(summary: false, webFetchCalls: calls)
        chat.streamingProviderOverride = provider
        chat.composerPolicySelection = .init(mode: .manual, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        var approvalIDs: [String] = []

        for (index, call) in calls.enumerated() {
            chat.draftText = "尝试读取指定网页，第 \(index + 1) 次。"
            chat.submitComposer()
            let turn = try #require(chat.turnTaskForTests(sessionID: fixture.sessionID))
            try #require(await waitUntil {
                bridge.approvalCenter.pendingRequest?.callID == call.id
            })
            let request = try #require(bridge.approvalCenter.pendingRequest)
            #expect(request.toolName == WebFetchToolContract.toolName)
            #expect(request.webFetchAuthority == "127.0.0.1:443")
            #expect(!approvalIDs.contains(request.requestID))
            approvalIDs.append(request.requestID)

            try #require(await waitUntil {
                consumer.readOnlyProjection.approvalHistory.contains {
                    $0.receiptID == request.requestID && $0.status == .waiting
                }
            })
            let waiting = try #require(consumer.readOnlyProjection.approvalHistory.first {
                $0.receiptID == request.requestID
            })
            if request.persistentAllowOffer?.isAvailable == true {
                bridge.approvalCenter.selectPersistentAllow(true)
            }
            bridge.approvalCenter.approvePending()
            if request.requiresSecondConfirmation {
                try #require(bridge.approvalCenter.awaitingConfirmation)
                bridge.approvalCenter.confirmPending()
            }
            await turn.value
            #expect(bridge.approvalCenter.pendingRequest == nil)

            let modelHistory = try #require(provider.requests.dropFirst(index * 2 + 1).first)
            let result = try #require(modelHistory.first {
                $0.role == .tool && $0.toolCallID == call.id
            })
            #expect(result.content.contains("域名解析到非公网地址，已阻止连接。请核对目标网站和网络配置后重试。"))
            #expect(!result.content.contains(target))
            #expect(!result.content.contains("127.0.0.1"))
            #expect(!result.content.contains("WebFetchPinnedError"))

            let matching = consumer.readOnlyProjection.approvalHistory.filter {
                $0.receiptID == request.requestID
            }
            try #require(matching.count == 1)
            let settled = try #require(matching.first)
            #expect(settled.id == waiting.id)
            #expect(settled.approvalCompositeKey == waiting.approvalCompositeKey)
            #expect(settled.approvalIdentityDigest == waiting.approvalIdentityDigest)
            #expect(settled.status == .succeeded)
            #expect(settled.approvalDecision == .approved)
            let card = ToolEventCard.displayModel(for: settled)
            #expect(card.summary == "审批通过：web_fetch")
            #expect(card.status != "已拒绝" && card.status != "已取消")
            #expect(rules.allRules() == beforeRules)
            #expect(ledger.pendingReceipts.isEmpty && ledger.facts.isEmpty)
        }
        #expect(provider.requests.count == 4)
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    @MainActor private final class Fixture {
        let profile: RuntimeIsolationProfile
        let settings: SettingsCenter
        let defaults: UserDefaults
        let sessionID = UUID()

        init(longHistory: Bool = true) throws {
            profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "ContextBoundary0715",
                processEnvironment: [:], processArguments: ["MinisCanvasAppTests.xctest"],
                canvasRuntimeState: .disabled)
            defaults = profile.makeUserDefaults()
            let keychain = profile.makeKeychainStore()
            let sessions = SessionStore(directory: profile.sessionDirectory)
            var history = [LLMMessage(role: .user,
                content: "Goal: compare repair choices. Keep the original title. Earlier authorization was read-only.")]
            for option in 0..<(longHistory ? 18 : 0) {
                history.append(LLMMessage(role: .assistant, content: (0..<24).map { detail in
                    "Option \(option), consideration \(detail): observed coefficient \(option * 31 + detail), cost \(option + detail + 2), dependency \(option * 7 - detail), and fallback \(detail % 5) need distinct evaluation."
                }.joined(separator: " ")))
                history.append(LLMMessage(role: .user,
                    content: "For option \(option), also compare dependency \(option + 4)."))
            }
            history.append(LLMMessage(role: .user, content: "Continue the comparison; do not write any files."))
            try sessions.updateSession(ChatSession(id: sessionID.uuidString,
                title: "owned manual context boundary", messages: history))
            let readiness = ProviderReadinessStore(directory: profile.providerConfigurationDirectory)
            #expect(readiness.upsert([ProviderReadinessPersistenceRecord(
                providerID: Provider.providerID, modelID: Provider.modelID,
                status: .passed, readinessState: .mock,
                checkedAt: Date(timeIntervalSince1970: 1_000), evidenceID: "owned0715", isApplied: true,
                discoveryReceiptID: "discovery0715", discoveredAt: Date(timeIntervalSince1970: 1_000),
                applyReceiptID: "provider-readiness-apply:0715", appliedAt: Date(timeIntervalSince1970: 1_001))]))
            settings = SettingsCenter(settingsStore: SettingsStore(directory: profile.settingsDirectory),
                envStore: EnvVarStore(directory: profile.providerConfigurationDirectory, keychain: keychain,
                    privacyStore: EnvVarPrivacyStore(defaults: defaults)),
                memoryStore: MemoryStore(directory: profile.memoryDirectory),
                memoryFileStore: MemoryFileStore(directory: profile.rootDirectory.appendingPathComponent("memory-files")),
                sessionStore: sessions, logManager: profile.makeLogManager(),
                mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
                skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")),
                usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain),
                providerReadinessTransport: FailClosedProviderReadinessTransport(),
                providerReadinessDeployment: .mock, providerReadinessStore: readiness)
        }

        func makeBridge(sessions: SessionStore) throws -> BridgeStore {
            let badges = SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges"))
            let bridge = BridgeStore(shortcutStore: ShortcutStore(defaults: defaults),
                preferencesDefaults: defaults, logManager: settings.logManager,
                workflowStore: WorkflowStore(storeDirectory: profile.rootDirectory.appendingPathComponent("workflows")),
                sessionBadgeStore: badges, sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
                canvasRuntimeState: .disabled,
                agentTaskStore: try AgentTaskStore(persistenceURL: profile.rootDirectory.appendingPathComponent("tasks0715.json")),
                contextManifestStore: try ContextManifestStore(persistenceURL: profile.rootDirectory.appendingPathComponent("manifest0715.json")),
                memoryStore: settings.memoryStore, memoryProposalConsumer: settings.memoryProposalConsumer,
                providerReadinessStore: settings.providerReadinessStore,
                taskCenterBindingPersistenceURL: profile.rootDirectory.appendingPathComponent("task-center0715.json"),
                canvasFeatureLane: .phase3NonCanvas,
                speechToolDirectObservationProvider: { _ in SpeechToolDirectObservations() })
            #expect(bridge.chat.attachPersistence(sessions, badgeStore: badges))
            bridge.bindProductionEffectiveSettingsSource { [settings] in settings.bl6EffectiveSettingsSnapshot }
            return bridge
        }

        func attach(_ bridge: BridgeStore) async {
            await bridge.attachProductionServices(agentSettings: settings.settings.agent,
                fileAccessAllowedRoot: profile.rootDirectory, fileAccessDeniedRoots: [],
                sessionDirectory: profile.sessionDirectory, mcpManager: settings.mcpManager,
                skillStore: settings.skillStore, policyDefaults: settings.policyRuntimeDefaults,
                canvasRuntimeState: .disabled, externalRunners: [:], externalNetworkAllowed: true,
                sessionReadSecretStore: settings.envStore).value
        }
    }

    private final class Provider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
        static let providerID = "owned-context0715"
        static let modelID = "owned-context0715"
        static let summaryConstraint = "Keep the original title and compare repairs under read-only authorization."
        let name = Provider.providerID
        private var storedModel = LLMModel(id: Provider.modelID, displayName: "Owned context", provider: Provider.providerID,
            contextWindow: 128_000)
        var model: LLMModel {
            get { lock.withLock { storedModel } }
            set { lock.withLock { storedModel = newValue } }
        }
        private var storedRuntimeMaterial: String? = "owned-context0715-in-memory"
        var runtimeConfigurationMaterial: String? {
            get { lock.withLock { storedRuntimeMaterial } }
            set { lock.withLock { storedRuntimeMaterial = newValue } }
        }
        var capabilities: Set<ProviderCapability> { [.tools] }
        private let summary: Bool
        private let webFetchCalls: [LLMToolCall]
        private let lock = NSLock()
        private var captured: [[LLMMessage]] = []
        var requests: [[LLMMessage]] { lock.withLock { captured } }
        init(summary: Bool, webFetchCalls: [LLMToolCall] = []) {
            self.summary = summary
            self.webFetchCalls = webFetchCalls
        }

        func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                         temperature: Double?) async throws -> LLMResponse {
            guard summary else { throw CocoaError(.featureUnsupported) }
            lock.withLock { captured.append(messages) }
            return LLMResponse(text: Self.summaryConstraint,
                stopReason: "stop", usage: nil)
        }

        func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                         maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
            guard !summary else { throw CocoaError(.featureUnsupported) }
            let requestIndex = lock.withLock {
                let index = captured.count
                captured.append(messages)
                return index
            }
            if requestIndex.isMultiple(of: 2), webFetchCalls.indices.contains(requestIndex / 2) {
                guard tools.contains(where: { $0.name == WebFetchToolContract.toolName }) else {
                    throw CocoaError(.featureUnsupported)
                }
                return LLMResponse(text: "", stopReason: "tool_calls", usage: nil,
                    toolCalls: [webFetchCalls[requestIndex / 2]])
            }
            return LLMResponse(text: "Owned ordinary continuation completed without executing a tool.", stopReason: "stop", usage: nil)
        }

        func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                           temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
            throw CocoaError(.featureUnsupported)
        }
    }
}
