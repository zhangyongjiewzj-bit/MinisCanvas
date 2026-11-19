import Darwin
import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Fixed local model input only. Its final answer makes no execution claim.
private final class Cancelled3299Provider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "tool3283-local"
    private var configurationMaterial: String? = "tool3283-fixed-local"
    var runtimeConfigurationMaterial: String? {
        get { lock.withLock { configurationMaterial } }
        set { lock.withLock { configurationMaterial = newValue } }
    }
    let capabilities: Set<ProviderCapability> = [.tools]
    private let lock = NSLock()
    private var currentModel = LLMModel(id: "tool3283", displayName: "Synthetic3283", provider: "tool3283-local")
    var model: LLMModel {
        get { lock.withLock { currentModel } }
        set { lock.withLock { currentModel = newValue } }
    }
    private var replies: [String] = []
    private var replyDelays: [Duration?] = []
    private var captured: [[LLMMessage]] = []
    func configure(_ replies: [String], delays: [Duration?] = []) {
        lock.withLock {
            self.replies = replies
            replyDelays = delays
        }
    }
    func requests() -> [[LLMMessage]] { lock.withLock { captured } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        let (reply, delay): (String?, Duration?) = lock.withLock {
            captured.append(messages)
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

@Suite("Stopped exact tuple waits for durable cancelled fact and rejects late writes")
@MainActor
struct CancelledToolProjection3299Tests {
    private struct Fixture {
        let bridge: BridgeStore
        let settings: SettingsCenter
        let sessions: SessionStore
    }
    private func makeRoot() throws -> URL {
        let ownedTestRoot = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let root = URL(fileURLWithPath: ownedTestRoot).appendingPathComponent("Tool3283-" + UUID().uuidString)
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return root
    }
    private func makeBridge(root: URL, provider: Cancelled3299Provider,
                            deadlineHorizon: TimeInterval = 600) throws -> Fixture {
        let defaults = try #require(UserDefaults(suiteName: "tool3283-" + UUID().uuidString))
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let now = Date()
        let lineage = ProviderReadinessLineage.derived(providerID: provider.name, modelID: provider.model.id, checkedAt: now)
        #expect(readiness.upsert([ProviderReadinessPersistenceRecord(providerID: provider.name,
            modelID: provider.model.id, status: .passed, readinessState: .mock, checkedAt: now,
            evidenceID: "tool3283-owned-synthetic", isApplied: false,
            discoveryReceiptID: lineage.discoveryReceiptID, discoveredAt: lineage.discoveredAt)]))
        try #require(readiness.applyDiscoveredModels(providerID: provider.name,
            modelIDs: [provider.model.id], appliedAt: now.addingTimeInterval(1)).count == 1)
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let log = LogManager(directory: root.appendingPathComponent("logs"))
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let settings = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: sessions,
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: log,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: skills,
            usageStore: UsageStore(domain: .suite("tool3283-settings-" + UUID().uuidString)),
            shortcutStore: ShortcutStore(defaults: defaults),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock, providerReadinessStore: readiness)
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            canvasFactory: { _ in preconditionFailure("3283 is non-Canvas") },
            agentTaskStore: try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json")),
            contextManifestStore: try ContextManifestStore(persistenceURL: root.appendingPathComponent("manifests.json")),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            providerReadinessStore: readiness,
            taskCenterBindingPersistenceURL: root.appendingPathComponent("bindings.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
            })
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        try #require(bridge.chat.attachPersistence(sessions, badgeStore: badges))
        bridge.attachProductionServices(fileAccessAllowedRoot: root, fileAccessDeniedRoots: [],
            sessionDirectory: sessions.directory,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"),
                                        keychain: KeychainStore(backing: InMemoryKeychainBacking())),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            policyDefaults: ProductionPolicyDefaults(budget: 100, deadlineHorizon: deadlineHorizon,
                                                     autonomyLevel: .l3, networkDomains: []),
            externalRunners: [:],
            sessionReadSecretStore: EnvVarStore(directory: root.appendingPathComponent("env"),
                                               keychain: KeychainStore(backing: InMemoryKeychainBacking())))
        try #require(bridge.chat.sessionStore === sessions)
        try #require(bridge.chat.sessionManager?.store === sessions)
        try #require(bridge.chat.sessionManager?.badgeStore === badges)
        try #require(bridge.chat.agentEngine is AgentLoopChatEngine)
        bridge.updateApprovalPolicy(.alwaysAsk)
        bridge.chat.streamingProviderOverride = provider
        return Fixture(bridge: bridge, settings: settings, sessions: sessions)
    }

    private func calls(_ values: [(String, String, [String: Any])]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["tool_calls": values.map {
            ["id": $0.0, "name": $0.1, "input": $0.2] as [String: Any]
        }]), as: UTF8.self)
    }

    private final class Timeline {
        private(set) var rows: [[String: String]] = []
        func record(_ stage: String, _ values: [String: String] = [:]) {
            rows.append(values.merging(["stage": stage,
                "time": String(Date().timeIntervalSince1970)]) { _, new in new })
        }
        func persist(to root: URL) throws {
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .prettyPrinted])
            try data.write(to: root.appendingPathComponent("cancel-projection-timeline3299.json"))
        }
    }
    private func processWitness(pid: Int32) -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "pid=,ppid=,pgid=,stat=,etime=,comm="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        } catch { return "owned process observation unavailable" }
    }

    private final class Watchdog {
        var fired = false
        var deadlineElapsed = false
        var ownerWasLiveAtDeadline: Bool?
    }
    private func watchdog(
        _ chat: ChatStore, sessionID: UUID, execution: AgentExecutionIdentity,
        timeline: Timeline, stage: String
    ) -> (Watchdog, Task<Void, Never>) {
        let probe = Watchdog()
        let task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            probe.deadlineElapsed = true
            let registered = chat.turnTaskForTests(sessionID: sessionID) != nil
            let sameExecution = chat.executionSnapshot(forSessionID: sessionID)?.executionIdentity == execution
            let active = chat.activeSessionID == sessionID
            let ownerLive = registered && sameExecution && active
            probe.ownerWasLiveAtDeadline = ownerLive
            timeline.record(stage + "-deadline", ["deadlineElapsed": "true",
                "boundSession": sessionID.uuidString, "boundOperation": execution.operationID,
                "registered": String(registered), "sameExecution": String(sameExecution),
                "activeSession": String(active), "ownerLive": String(ownerLive)])
            // The ceiling still expires after eight seconds. A retired turn
            // has no authority to stop a different or newer active request.
            guard ownerLive else { return }
            probe.fired = true
            chat.stopStreaming()
        }
        return (probe, task)
    }
    private func waitForPrompt(_ bridge: BridgeStore) async throws -> ApprovalRequest {
        for _ in 0..<400 {
            if let request = bridge.approvalCenter.pendingRequest { return request }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(bridge.approvalCenter.pendingRequest, "actual request never reached the production center")
    }
    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @Test(arguments: ["native", "expired", "foreign", "mixed", "card"])
    func nativeApproveConsumesTwoIndependentStepsOfTheActualTurnGate(scenario: String) async throws {
        let root = try makeRoot(), provider = Cancelled3299Provider()
        let fixture = try makeBridge(root: root, provider: provider)
        defer { withExtendedLifetime(fixture.settings) {} }
        let bridge = fixture.bridge, chat = bridge.chat
        let center = ComposerCommandAdjudicationCenter()
        try #require(ProductionCommandRegistryWiring.bind(bridge: bridge, center: center))
        chat.onComposerCommandPolicy = { request, snapshot in
            center.evaluate(request: request, snapshot: snapshot, facts: chat.composerPolicyFacts)
        }
        center.preparePresentedToolApproval = { request, snapshot, facts in
            try bridge.prepareComposerPresentedToolApproval(request: request, snapshot: snapshot, facts: facts)
        }
        center.applyPresentedToolApproval = { context in
            try bridge.applyComposerPresentedToolApproval(context)
        }
        defer {
            chat.onComposerCommandPolicy = nil
            bridge.approvalCenter.dismissPending()
            chat.stopAllStreamingForSafety()
        }
        let result = root.appendingPathComponent("native-approval-effect")
        // 只有不可逆命令才有第二次确认（2026-11-16）：加一个 rm 子命令，让这张卡保持两步确认。
        let command = "rm -f " + quote(result.path + ".stale") + "; printf %s approved > " + quote(result.path)
        provider.configure([try calls([("native-approve", "shell_execute", ["command": command, "timeout": 6])])])
        chat.composerPolicySelection.mode = .autoEdit
        chat.draftText = "Start the owned tool request"
        chat.submitComposer()
        let session = try #require(chat.activeSessionID)
        let snapshot = try #require(chat.lastComposerSubmissionSnapshot)
        let turn = try #require(chat.turnTaskForTests(sessionID: session))
        let execution = try #require(chat.activeExecutionIdentity(for: session))
        let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        let request = try await waitForPrompt(bridge)
        try #require(request.toolName == "shell_execute" && request.callID == "native-approve")
        try #require(request.binding == nil)
        try #require(request.sessionID == session.uuidString)
        try #require(request.turnID == snapshot.turnID)
        try #require(request.taskID == snapshot.taskID)
        try #require(request.attemptID == snapshot.attemptID)
        try #require(request.messageID == snapshot.messageID)
        try #require(request.requiresSecondConfirmation)
        try #require(request.identityDigest?.isEmpty == false)
        let lifecycle = try #require(bridge.approvalCenter.pendingRequestLifecycleID)
        let waitingFacts = chat.composerPolicyFacts
        try #require(request.grantEpoch == waitingFacts.grantEpoch
            && request.policyRevision == waitingFacts.revision)
        // /status uses its own policy preparation without ending the tool turn.
        chat.draftText = "/status"
        chat.submitComposer()
        try #require(chat.lastComposerCommandReceipt?.commandID == "status"
            && chat.lastComposerCommandReceipt?.disposition == .execute)
        let observedStatus = try #require(chat.lastComposerSubmissionSnapshot)
        let factsAfterStatus = chat.composerPolicyFacts
        try #require(factsAfterStatus.grantEpoch != waitingFacts.grantEpoch
            && observedStatus.grantEpoch == factsAfterStatus.grantEpoch
            && observedStatus.turnID != snapshot.turnID)
        try #require(bridge.approvalCenter.pendingRequestLifecycleID == lifecycle)
        try #require(bridge.approvalCenter.pendingRequest == request)
        chat.composerPolicySelection.mode = .bypassPermission
        try #require(chat.confirmComposerBypass(for: session))

        if scenario == "foreign" {
            let foreign = chat.applyNewSession(title: "Other session")
            try #require(foreign != session && chat.confirmComposerBypass(for: foreign))
            chat.draftText = "/approve"
            chat.submitComposerFromKeyboard()

            #expect(chat.lastComposerCommandReceipt?.disposition == .reject)
            #expect(center.projection?.text.contains("有效工具审批请求") == true)
            #expect(center.pendingAdjudication == nil)
            #expect(bridge.approvalCenter.pendingRequestLifecycleID == lifecycle)
            #expect(!bridge.approvalCenter.awaitingConfirmation)
            #expect(!FileManager.default.fileExists(atPath: result.path))
            return
        }

        let firstCardAction = bridge.approvalCenter.actionsForPresentedRequest()
        var firstReceiptID: UUID?
        for confirming in [false, true] {
            try await Task.sleep(for: .milliseconds(550))
            try #require(chat.isActiveSessionGenerating && !FileManager.default.fileExists(atPath: result.path))
            try #require(bridge.approvalCenter.pendingRequestLifecycleID == lifecycle)
            try #require(bridge.approvalCenter.awaitingConfirmation == confirming)
            if confirming, scenario == "expired" {
                let previousReceipt = try #require(chat.lastComposerCommandReceipt)
                try #require(waitingFacts.expiresAt > Date())
                let expired = ComposerPolicyFactSource(
                    knownCapabilities: factsAfterStatus.knownCapabilities,
                    grantedCapabilities: factsAfterStatus.grantedCapabilities,
                    capabilityGrantBindings: factsAfterStatus.capabilityGrantBindings,
                    allowedWriteRoots: factsAfterStatus.allowedWriteRoots,
                    workspaceID: factsAfterStatus.workspaceID,
                    revision: factsAfterStatus.revision,
                    grantEpoch: factsAfterStatus.grantEpoch,
                    leaseID: factsAfterStatus.leaseID,
                    expiresAt: Date().addingTimeInterval(-1),
                    autonomyCeiling: factsAfterStatus.autonomyCeiling
                )
                chat.configureComposerPolicy(expired)
                try #require(chat.hasNativeCommandBypassConfirmation)
                chat.draftText = "/approve"
                chat.submitComposerFromKeyboard()

                #expect(chat.composerPolicyFacts == expired)
                #expect(chat.lastComposerCommandReceipt == previousReceipt)
                #expect(chat.draftText == "/approve")
                #expect(chat.pastedTextActionFeedback != nil)
                #expect(bridge.approvalCenter.pendingRequestLifecycleID == lifecycle)
                #expect(bridge.approvalCenter.awaitingConfirmation)
                #expect(!FileManager.default.fileExists(atPath: result.path))
                return
            }

            if scenario == "card" {
                bridge.approvalCenter.actionsForPresentedRequest().approve()
                continue
            }
            let competingCardAction: ApprovalPromptCenter.PresentationActions?
            if scenario == "mixed", confirming {
                // A stale first-stage button cannot consume stage two, even
                // after the timing guard.
                firstCardAction.approve()
                try #require(bridge.approvalCenter.pendingRequestLifecycleID == lifecycle)
                try #require(bridge.approvalCenter.awaitingConfirmation)
                #expect(!FileManager.default.fileExists(atPath: result.path))
                competingCardAction = bridge.approvalCenter.actionsForPresentedRequest()
            } else {
                competingCardAction = nil
            }

            chat.draftText = "/approve"
            chat.submitComposerFromKeyboard()
            // Both actions target the same final stage of the same waiter.
            // Deliver them back-to-back on MainActor before the turn resumes.
            competingCardAction?.approve()
            #expect(chat.composerPolicyFacts == factsAfterStatus)
            #expect(chat.lastComposerSubmissionSnapshot == observedStatus)
            let receipt = try #require(chat.lastComposerCommandReceipt)
            try #require(receipt.commandID == "approve" && receipt.disposition == .execute)
            #expect(receipt.taskID == snapshot.taskID && receipt.turnID == snapshot.turnID
                && receipt.attemptID == snapshot.attemptID)
            #expect(center.pendingAdjudication == nil && chat.activeQueuedComposerMessages.isEmpty)
            if confirming {
                #expect(receipt.requestID != firstReceiptID)
            } else {
                firstReceiptID = receipt.requestID
                #expect(bridge.approvalCenter.awaitingConfirmation)
                #expect(!FileManager.default.fileExists(atPath: result.path))
            }
        }
        try #require(bridge.approvalCenter.pendingRequest == nil)
        await turn.value
        #expect(try Data(contentsOf: result) == Data("approved".utf8))
        let effects = engine.toolExecutionFactLedger.facts.filter { $0.toolCallID == request.callID }
        let effect = try #require(effects.first)
        #expect(effects.count == 1 && effect.status == .succeeded)
        #expect(effect.executionIdentity == execution && effect.attemptID == request.attemptID)
        #expect(effect.compositeKey?.messageID == request.messageID)

        chat.draftText = "/approve"
        chat.submitComposerFromKeyboard()
        #expect(chat.lastComposerCommandReceipt?.disposition == .reject)
        #expect(center.projection?.text.contains("有效工具审批请求") == true)
        #expect(center.pendingAdjudication == nil)
        #expect(engine.toolExecutionFactLedger.facts.filter { $0.toolCallID == request.callID } == effects)
        #expect(try Data(contentsOf: result) == Data("approved".utf8))
    }

    @Test("actual stop durable receipt settles original tuple across next session", arguments: [false, true])
    func actualRunningShellStopHasTypedCancelledTerminal(switchBeforeSettlement: Bool) async throws {
        let root = try makeRoot(), provider = Cancelled3299Provider()
        let fixture = try makeBridge(root: root, provider: provider)
        defer { withExtendedLifetime(fixture.settings) {} }
        let bridge = fixture.bridge, chat = bridge.chat
        let timeline = Timeline()
        timeline.record("fixture-ready", ["switch": String(switchBeforeSettlement)])
        defer { try? timeline.persist(to: root) }
        chat.turnFailureObserverForTests = { observation in
            timeline.record("typed-failure", ["phase": observation.stage.rawValue,
                "type": observation.errorType, "case": observation.errorCaseName ?? "none",
                "session": observation.sessionID?.uuidString ?? "none",
                "operation": observation.executionIdentity.operationID])
        }
        let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        let ready = root.appendingPathComponent("cancel-shell-ready")
        let forbidden = root.appendingPathComponent("late-shell-effect")
        let pidFile = root.appendingPathComponent("owned-shell.pid")
        let command = "printf %s \"$$\" > " + quote(pidFile.path) + "; printf ready > " + quote(ready.path)
            + "; /bin/sleep 3; printf late > " + quote(forbidden.path)
        provider.configure([try calls([("cancel3283", "shell_execute", ["command": command, "timeout": 6])])])
        chat.composerPolicySelection = ComposerPolicySelection(mode: .autoEdit, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        chat.setOutputMode(.concise)
        chat.draftText = "3283 owned running shell stop"
        chat.submitComposer()
        timeline.record("old-submit")
        let session = try #require(chat.activeSessionID)
        let task = try #require(chat.turnTaskForTests(sessionID: session))
        let identity = try #require(chat.executionSnapshot(forSessionID: session)?.executionIdentity)
        let (probe, ceiling) = watchdog(chat, sessionID: session, execution: identity,
            timeline: timeline, stage: "old")
        defer { ceiling.cancel(); bridge.approvalCenter.dismissPending() }
        let request = try await waitForPrompt(bridge)
        #expect(request.toolName == "shell_execute" && request.callID == "cancel3283")
        let approvalLifecycleID = try #require(bridge.approvalCenter.pendingRequestLifecycleID)
        for confirming in [false, true] {
            guard bridge.approvalCenter.pendingRequestLifecycleID == approvalLifecycleID else { break }
            try #require(bridge.approvalCenter.awaitingConfirmation == confirming)
            // Use the real action only after this step's 500 ms guard.
            try await Task.sleep(for: .milliseconds(550))
            try #require(bridge.approvalCenter.pendingRequestLifecycleID == approvalLifecycleID)
            try #require(bridge.approvalCenter.pendingRequest?.id == request.id)
            try #require(bridge.approvalCenter.awaitingConfirmation == confirming)
            try #require(bridge.approvalCenter.isPromptPresented)
            bridge.approvalCenter.actionsForPresentedRequest().approve()
        }
        try #require(bridge.approvalCenter.pendingRequestLifecycleID != approvalLifecycleID,
            "real approval waiter must resolve before observing shell execution")
        for _ in 0..<400 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(FileManager.default.fileExists(atPath: ready.path))
        let running = try #require(chat.conversationEvents.first { $0.kind == .tool && $0.toolCallID == "cancel3283" && $0.status == .running })
        #expect(running.receiptID == nil && engine.toolExecutionFactLedger.pendingReceipts.count == 1)
        let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8)))
        timeline.record("owned-shell-running", ["process": processWitness(pid: pid)])
        let originalMessages = chat.sessions.first { $0.id == session }?.messages.map(\.id)
        let revisionBeforeStop = chat.cancelledToolSettlementRevision
        chat.stopStreaming()
        timeline.record("old-stop", ["revision": String(chat.cancelledToolSettlementRevision)])
        chat.stopStreaming() // duplicate stop cannot register or append twice
        if switchBeforeSettlement { chat.newSession() }
        await task.value
        timeline.record("old-task-returned", ["watchdog": String(probe.fired)])
        ceiling.cancel() // This watchdog owns the stopped turn, not the next turn.
        // The App task can finish before the original owned shell worker has
        // reaped. Wait for the real durable settlement instead of inventing it.
        for _ in 0..<400 {
            if !engine.toolExecutionFactLedger.facts.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!probe.fired && !chat.isStreaming)
        #expect(!probe.deadlineElapsed || probe.ownerWasLiveAtDeadline == false)
        let fact = try #require(engine.toolExecutionFactLedger.facts.first)
        #expect(fact.toolCallID == "cancel3283" && fact.status == .cancelled)
        #expect(fact.executionIdentity == identity && fact.elapsedMilliseconds != nil)
        #expect(fact.failureCategory == nil && engine.toolExecutionFactLedger.pendingReceipts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: forbidden.path))
        for _ in 0..<400 {
            if chat.conversationEvents.first(where: { $0.toolCompositeKey == running.toolCompositeKey })?.receiptID == fact.receiptID
                && chat.cancelledToolSettlementRevision == revisionBeforeStop + 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let terminal = try #require(chat.conversationEvents.first { $0.kind == .tool && $0.toolCompositeKey == running.toolCompositeKey })
        #expect(terminal.status == .cancelled && terminal.receiptID == fact.receiptID)
        #expect(ToolEventCard.displayModel(for: terminal).status == "已取消")
        // Durable settlement can precede the actual Process waiter/reap.
        // Preserve the OS terminal assertion with a bounded physical-exit wait.
        timeline.record("fact-and-journal", ["process": processWitness(pid: pid),
            "revision": String(chat.cancelledToolSettlementRevision)])
        for _ in 0..<400 {
            if kill(pid, 0) == -1 && errno == ESRCH { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        timeline.record("physical-exit", ["process": processWitness(pid: pid)])
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(chat.cancelledToolSettlementRevision == revisionBeforeStop + 1)
        let originalEvents = chat.conversationEvents
        let stoppedBodies = chat.sessions.first { $0.id == session }?.messages.map { $0.id.uuidString + ":" + $0.content }
        let lifecycleURL = fixture.sessions.directory.appendingPathComponent("tool-lifecycle-events-v1.json")
        let durable = try MinisCore.ToolLifecycleConsumer(persistenceURL: lifecycleURL)
        #expect(durable.events.first { $0.toolCompositeKey == running.toolCompositeKey }?.receiptID == fact.receiptID)
        #expect(chat.sessions.first { $0.id == session }?.messages.map(\.id) == originalMessages)
        timeline.record("before-next", ["requests": String(provider.requests().count)])
        provider.configure(["NEXT_NORMAL_3299"])
        chat.draftText = "NEXT_USER_3299"
        chat.submitComposer()
        timeline.record("next-submit")
        let nextSession = try #require(chat.activeSessionID)
        let nextExecution = try #require(chat.executionSnapshot(forSessionID: nextSession)?.executionIdentity)
        let (nextProbe, nextCeiling) = watchdog(chat, sessionID: nextSession, execution: nextExecution,
            timeline: timeline, stage: "next")
        defer { nextCeiling.cancel() }
        let nextTask = try #require(chat.turnTaskForTests(sessionID: nextSession))
        await nextTask.value
        timeline.record("next-task-returned", ["watchdog": String(nextProbe.fired),
            "requests": String(provider.requests().count), "revision": String(chat.cancelledToolSettlementRevision)])
        #expect(!chat.isStreaming && !probe.fired && !nextProbe.fired)
        #expect(chat.messages.last?.content.contains("NEXT_NORMAL_3299") == true)
        #expect(chat.conversationEvents == originalEvents)
        #expect(chat.sessions.first { $0.id == session }?.messages.prefix(stoppedBodies?.count ?? 0).map { $0.id.uuidString + ":" + $0.content } == stoppedBodies)
        #expect(!FileManager.default.fileExists(atPath: forbidden.path))
        #expect(engine.toolExecutionFactLedger.facts == [fact])
        // This constructor takes over the durable writer lease. Perform the
        // cold readback only after the live engine's next turn has completed.
        let reopened = try ToolExecutionFactLedger(persistenceURL: fixture.sessions.directory.appendingPathComponent("tool-execution-facts-v4.json"))
        #expect(reopened.facts == [fact] && reopened.pendingReceipts.isEmpty)
    }
}
