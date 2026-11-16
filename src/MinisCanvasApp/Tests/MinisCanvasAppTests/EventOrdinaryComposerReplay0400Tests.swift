import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Local reply capture with its own explicit identity. It is not SharedMock,
/// an SDK transport, or an authority source; production routing stays intact.
private final class EventOrdinaryProvider0400: LLMProvider,
    ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "event0400-owned-local"
    var model = LLMModel(id: "event0400", displayName: "Owned event capture",
                         provider: "event0400-owned-local")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "event0400-owned-local-v1"
    private let lock = NSLock()
    private var count = 0
    private let envelope: String
    init(file: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: ["tool_calls": [[
            "id": "owned-write0400", "name": "file_write", "input": [
                "path": file.path, "content": "owned0400 effect\n原始字节\n", "append": false
            ]
        ]]])
        envelope = String(decoding: data, as: UTF8.self)
    }
    var calls: Int { lock.withLock { count } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        let index = lock.withLock { count += 1; return count }
        if index == 2 { print("EVENT0450_PROVIDER_INPUT " + messages.map { $0.content }.joined(separator: " | ")) }
        #expect(index <= 2, "recovery must not reenter the actual request producer")
        return LLMResponse(text: index == 1 ? envelope : "owned0400 completion",
                           stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        Issue.record("ordinary production AgentLoop unexpectedly used provider streaming")
        return AsyncThrowingStream { $0.finish() }
    }
}

/// Uses the existing production attach seam and returns an exact native gate
/// decision. It does not modify policy, request identity or receipt custody.
private actor EventExactApproval0400: ApprovalDelegate {
    let sessionID: String
    let expectedInputDigest: String
    init(sessionID: String, file: URL) throws {
        self.sessionID = sessionID
        expectedInputDigest = try ComposerToolInput(["path": file.path,
            "content": "owned0400 effect\n原始字节\n", "append": false]).digest
    }
    private(set) var calls = 0
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        calls += 1
        let exact = request.toolName == "file_write" && request.callID == "owned-write0400"
            && request.sessionID == sessionID && request.turnID != nil
            && request.taskID?.isEmpty == false && request.attemptID?.isEmpty == false
            && request.messageID?.isEmpty == false
            && request.policyRevision?.isEmpty == false && request.grantEpoch?.isEmpty == false
            && request.approvalScope == ComposerApprovalScope.request.rawValue
            && request.composerMode == ComposerTaskMode.manual.rawValue
            && request.inputDigest == expectedInputDigest && request.identityDigest?.count == 64
            && request.requiresApproval
        print("EVENT0450_APPROVAL tool=\(request.toolName) call=\(request.callID) expectedSession=\(sessionID) session=\(String(describing: request.sessionID)) turn=\(String(describing: request.turnID)) task=\(String(describing: request.taskID)) attempt=\(String(describing: request.attemptID)) message=\(String(describing: request.messageID)) inputDigestMatch=\(request.inputDigest == expectedInputDigest) identityDigest=\(String(describing: request.identityDigest)) exact=\(exact)")
        return ApprovalDecision(approved: exact, confirmed: exact,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

@Suite("EVENT1/4 ordinary composer producer and production Bridge replay", .serialized)
@MainActor
struct EventOrdinaryComposerReplay0400Tests {
    @Test(arguments: ["intact", "partial-utf8"])
    func ordinaryComposerPersistsItsOwnEventsAndRebindNeverRepeatsTheEffect(boundary: String) async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.temporaryDirectory.appendingPathComponent("event0400-\(boundary)-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        // All owned synthetic evidence is retained. This is cold composition
        // reconstruction, not OS App interruption/relaunch or a UI approval.
        let suite = formal.userDefaultsSuiteName + ".event0400." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let sessionsURL = root.appendingPathComponent("sessions")
        let sessions = SessionStore(directory: sessionsURL)
        let sessionID = UUID()
        _ = try sessions.createSession(id: sessionID.uuidString, title: "Owned event producer",
                                      projectID: "owned-project0400", workingDirectory: root.path)
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let provider = try EventOrdinaryProvider0400(file: root.appendingPathComponent("effect.txt"))
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let checkedAt = Date()
        let lineage = ProviderReadinessLineage.derived(providerID: provider.name,
            modelID: provider.model.id, checkedAt: checkedAt)
        try #require(readiness.upsert([ProviderReadinessPersistenceRecord(
            providerID: provider.name, modelID: provider.model.id, status: .passed,
            readinessState: .mock, checkedAt: checkedAt, evidenceID: "owned-event0400-local-capture",
            isApplied: false, discoveryReceiptID: lineage.discoveryReceiptID,
            discoveredAt: lineage.discoveredAt)]))
        try #require(readiness.applyDiscoveredModels(providerID: provider.name,
            modelIDs: [provider.model.id], appliedAt: checkedAt.addingTimeInterval(1)).count == 1)
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let logs = LogManager(directory: root.appendingPathComponent("logs"))
        let env = EnvVarStore(directory: root.appendingPathComponent("environment"), keychain: keychain,
                             privacyStore: EnvVarPrivacyStore(defaults: defaults))
        let mcp = MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain)
        let settings = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: env, memoryStore: memory,
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: sessions, logManager: logs, mcpManager: mcp, skillStore: skills,
            usageStore: UsageStore(domain: .suite(suite)),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock, providerReadinessStore: readiness)
        let approvals = try EventExactApproval0400(sessionID: sessionID.uuidString, file: root.appendingPathComponent("effect.txt"))
        var agentSettings = AgentSettings.default
        agentSettings.approvalPolicy = .alwaysAsk
        func makeBridge() throws -> BridgeStore {
            BridgeStore(shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
                logManager: logs,
                workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
                sessionDocumentStore: SessionDocumentStore(directory: sessionsURL),
                agentTaskStore: try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json")),
                contextManifestStore: try ContextManifestStore(persistenceURL: root.appendingPathComponent("contexts.json")),
                memoryStore: memory, providerReadinessStore: readiness, canvasFeatureLane: .phase3NonCanvas,
                speechToolDirectObservationProvider: { _ in
                    SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
                })
        }
        func attach(_ bridge: BridgeStore) async {
            await bridge.attachProductionServices(agentSettings: agentSettings,
                fileAccessAllowedRoot: root, fileAccessDeniedRoots: [], sessionDirectory: sessionsURL,
                mcpManager: mcp, skillStore: skills, approvalDelegateOverride: approvals,
                externalRunners: [:], externalNetworkAllowed: true, sessionReadSecretStore: env).value
        }
        let bridge = try makeBridge()
        await attach(bridge)
        let chat = bridge.chat
        let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        _ = try #require(chat.turnRuntimeSnapshotFactory)
        _ = try #require(chat.chatModelPickerReceipt(providerID: provider.name, modelID: provider.model.id))
        chat.streamingProviderOverride = provider
        chat.switchSession(id: sessionID)
        #expect(chat.activeSessionID == sessionID)
        chat.draftText = "perform the exact owned file write0400"
        chat.submitComposer()
        let turnIdentity = try #require(chat.activeExecutionIdentity(for: sessionID))
        let task = try #require(chat.turnTaskForTests(sessionID: sessionID))
        await task.value
        #expect(!chat.isStreaming)
        #expect(chat.terminalReceipt(for: turnIdentity)?.outcome == .succeeded)
        #expect(provider.calls == 2)
        let approvalCallsBeforeReplay = await approvals.calls
        #expect(approvalCallsBeforeReplay == 1)
        let facts = engine.toolExecutionFactLedger.facts
        let fact = try #require(facts.first)
        #expect(facts.count == 1 && engine.toolExecutionFactLedger.pendingReceipts.isEmpty)
        #expect(fact.status == .succeeded && fact.toolName == "file_write")
        #expect(fact.executionIdentity == turnIdentity)
        let key = try #require(fact.compositeKey)
        #expect(key.sessionID == sessionID.uuidString && key.toolCallID == "owned-write0400")
        let trustedEvents = chat.conversationEvents
        let toolEvent = try #require(trustedEvents.first { $0.receiptID == fact.receiptID })
        #expect(toolEvent.kind == .tool && toolEvent.status == .succeeded)
        #expect(toolEvent.identity.sessionID == sessionID.uuidString)
        let lifecycleURL = sessionsURL.appendingPathComponent("tool-lifecycle-events-v1.json")
        let journalURL = lifecycleURL.deletingPathExtension().appendingPathExtension("journal")
        let original = try Data(contentsOf: journalURL)
        let records = try original.split(separator: 0x0A).map {
            try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        let events = try records.map { try #require($0["event"] as? [String: Any]) }
        #expect(!events.isEmpty)
        #expect(records.allSatisfy { ($0["schemaVersion"] as? Int) == 1 })
        #expect(events.compactMap { $0["sequence"] as? Int } == Array(1...events.count))
        #expect(events.allSatisfy {
            ($0["kind"] as? String).flatMap { MinisCore.ConversationEventKind(rawValue: $0) } != nil
        })
        let file = root.appendingPathComponent("effect.txt")
        let effectBytes = try Data(contentsOf: file)
        #expect(effectBytes == Data("owned0400 effect\n原始字节\n".utf8))
        let inode = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber)
        let factURL = sessionsURL.appendingPathComponent("tool-execution-facts-v4.json")
        let factBytes = try Data(contentsOf: factURL)
        try factBytes.write(to: root.appendingPathComponent("fact-ledger-before-cold-reopen.bytes"))
        try original.write(to: root.appendingPathComponent("original-production-journal.bytes"))
        var input = original
        if boundary == "partial-utf8" {
            input.append(Data("{\"schemaVersion\":1,\"event\":{\"label\":\"".utf8))
            input.append(0xE4)
        }
        try input.write(to: root.appendingPathComponent("injected-tail.bytes"))
        try input.write(to: journalURL, options: [.atomic])
        let reopened = try makeBridge()
        await attach(reopened)
        _ = try await reopened.chat.awaitApprovalRecovery()
        #expect(reopened.chat.agentEngine is AgentLoopChatEngine)
        #expect(reopened.chat.conversationEvents == trustedEvents)
        #expect(try Data(contentsOf: journalURL) == original)
        let again = try ToolLifecycleConsumer(persistenceURL: lifecycleURL)
        #expect(again.events == trustedEvents && again.persistenceMetrics.totalWriteCount == 0)
        let approvalCallsAfterReplay = await approvals.calls
        #expect(provider.calls == 2 && approvalCallsAfterReplay == 1)
        #expect(try Data(contentsOf: file) == effectBytes)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber == inode)
        try Data(contentsOf: factURL).write(to: root.appendingPathComponent("fact-ledger-after-cold-reopen.bytes"))
        // The production constructor performs an exclusive writer takeover.
        // Preserve every payload field, while checking its native ownership
        // token/fence transition explicitly rather than expecting raw JSON
        // bytes to retain an obsolete writer identity.
        func verifyNativeTakeover(before: Data, after: Data) throws {
            var old = try #require(JSONSerialization.jsonObject(with: before) as? [String: Any])
            var new = try #require(JSONSerialization.jsonObject(with: after) as? [String: Any])
            let oldWriter = try #require(old["writerID"] as? String)
            let newWriter = try #require(new["writerID"] as? String)
            #expect(UUID(uuidString: oldWriter) != nil && UUID(uuidString: newWriter) != nil)
            #expect(newWriter != oldWriter)
            if let fence = old["fence"] as? Int {
                #expect(new["fence"] as? Int == fence + 1)
            } else {
                #expect(old["fence"] == nil && new["fence"] == nil)
            }
            old.removeValue(forKey: "writerID"); new.removeValue(forKey: "writerID")
            old.removeValue(forKey: "fence"); new.removeValue(forKey: "fence")
            #expect(NSDictionary(dictionary: old).isEqual(NSDictionary(dictionary: new)))
        }
        let reopenedBytes = try Data(contentsOf: factURL)
        try verifyNativeTakeover(before: factBytes, after: reopenedBytes)
        #expect(throws: ToolExecutionFactLedgerError.staleWriter) {
            try engine.toolExecutionFactLedger.mint(toolCallID: "stale-probe0400", toolName: "file_write",
                attemptID: fact.attemptID, attemptNumber: fact.attemptNumber, executionIdentity: turnIdentity)
        }
        #expect(try Data(contentsOf: factURL) == reopenedBytes)

        #expect(try ToolExecutionFactLedger(persistenceURL: factURL).facts == facts)
        let finalLedgerBytes = try Data(contentsOf: factURL)
        try finalLedgerBytes.write(to: root.appendingPathComponent("fact-ledger-after-final-constructor.bytes"))
        try verifyNativeTakeover(before: reopenedBytes, after: finalLedgerBytes)
        print("EVENT0400 ordinary=true boundary=\(boundary) provider=2 approval=1 facts=1 seqCount=\(events.count) replayEffectBytesAndInodeUnchanged=true root=\(root.path)")
        withExtendedLifetime(settings) {}
    }
}
