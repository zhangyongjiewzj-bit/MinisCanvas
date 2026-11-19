import Foundation
import Darwin
import Testing
@testable import MinisCore
@testable import MinisCanvasApp


private actor ChildMutationUserGate {
    private(set) var entered = false
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func park() async {
        entered = true
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; let pending = continuation; continuation = nil; pending?.resume() }
}

private actor ChildMutationUserApproval: ApprovalDelegate {
    struct Observation: Sendable {
        let request: ApprovalRequest
        let approved: Bool
    }
    private(set) var observations: [Observation] = []
    private var denyChild = false
    func setDenyChild(_ value: Bool) { denyChild = value }
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        let approved = !(denyChild && request.source != nil)
        observations.append(Observation(request: request, approved: approved))
        return ApprovalDecision(approved: approved, confirmed: approved,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

private final class ChildQueueUserDelegate: ApprovalDelegate, @unchecked Sendable {
    private let base: ApprovalPromptDelegate
    private let lock = NSLock()
    private var calls: [String: (ApprovalRequest, AgentExecutionContextSnapshot?, Task<ApprovalDecision, Never>, ApprovalPresentationContext?)] = [:]
    private var decisions: [String: ApprovalDecision] = [:]
    private var origins: [String: ApprovalExecutionOrigin] = [:]
    @MainActor init(center: ApprovalPromptCenter) { base = ApprovalPromptDelegate(center: center) }
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        let context = AgentExecutionContext.current
        let task = Task { await base.requestApproval(request) }
        let origin = ApprovalExecutionOriginContext.current
        lock.withLock {
            calls[request.requestID] = (request, context, task, ApprovalPresentationContext.current)
            origins[request.requestID] = origin
        }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        lock.withLock { decisions[request.requestID] = result }
        return result
    }
    func cancel(_ requestID: String) { lock.withLock { calls[requestID]?.2.cancel() } }
    func decision(_ requestID: String) -> ApprovalDecision? { lock.withLock { decisions[requestID] } }
    func origin(_ requestID: String) -> ApprovalExecutionOrigin? { lock.withLock { origins[requestID] } }
    var debugSummary: String { lock.withLock { calls.map { "\($0.value.0.toolName):\(String(describing: decisions[$0.key]?.status))" }.joined(separator: ",") } }
    func duplicate(_ requestID: String) async -> ApprovalDecision {
        guard let call = lock.withLock({ calls[requestID] }) else { return .deny }
        return await AgentExecutionContext.$current.withValue(call.1) {
            await ApprovalPresentationContext.$current.withValue(call.3) {
                await base.requestApproval(call.0)
            }
        }
    }
}

private final class ChildMutationUserProvider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "goal18-child-switch-local"
    var model = LLMModel(id: "goal18-child-switch-model", displayName: "Owned child switch", provider: "goal18-child-switch-local")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "owned-child-switch-offline-v1"
    let childID: String
    let effectTool: String
    private let input: [String: Any]
    private let gate: ChildMutationUserGate?
    private let readFullResult: Bool
    private let finalOutput: String
    private let parallelReads: Bool
    private let directorySequence: Bool
    private var directoryResults: [String: (body: String, error: Bool)] = [:]
    private var directoryGeneration: String?
    private var directoryIdentityStable = true
    private var directoryReaderObserved = false
    private var directoryReaderStopped = false
    private let directoryReaderReady = DispatchSemaphore(value: 0)
    private let directoryReaderDone = DispatchSemaphore(value: 0)
    var directoryToolResults: [String: (body: String, error: Bool)] { lock.withLock { directoryResults } }
    var directoryChildBinding: (generation: String?, stable: Bool) {
        lock.withLock { (directoryGeneration, directoryIdentityStable) }
    }
    // Same bounded FIFO admission witness as Privacy600: it observes only
    // this owned path opening, never access-time or file contents.
    func startDirectoryReaderWitness() throws {
        let path = try #require(input["next_path"] as? String)
        Thread.detachNewThread { [self] in
            directoryReaderReady.signal()
            let descriptor = open(path, O_WRONLY)
            if descriptor >= 0 {
                let stopped = lock.withLock {
                    if !directoryReaderStopped { directoryReaderObserved = true }
                    return directoryReaderStopped
                }
                if !stopped {
                    _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
                    let bytes = Array("N07 owned reader witness".utf8)
                    _ = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
                }
                close(descriptor)
            }
            directoryReaderDone.signal()
        }
        try #require(directoryReaderReady.wait(timeout: .now() + 2) == .success)
    }
    func finishDirectoryReaderWitness() throws -> Bool {
        if directoryReaderDone.wait(timeout: .now() + 1) == .success {
            return lock.withLock { directoryReaderObserved }
        }
        lock.withLock { directoryReaderStopped = true }
        let path = try #require(input["next_path"] as? String)
        let release = open(path, O_RDONLY | O_NONBLOCK)
        try #require(release >= 0)
        defer { close(release) }
        try #require(directoryReaderDone.wait(timeout: .now() + 4) == .success)
        return lock.withLock { directoryReaderObserved }
    }
    private var parallelCounts: [String: Int] = [:]
    private var parallelFeedback: [String: String] = [:]
    var parallelToolFeedback: [String: String] { lock.withLock { parallelFeedback } }
    private var resultResponse: String?
    private let lock = NSLock()
    private var rootCalls = 0
    private var childCalls = 0
    private var feedback: [String] = []
    private var returnedToolFeedback: [String] = []
    var fullResultResponse: String? { lock.withLock { resultResponse } }
    var childRequestCount: Int { lock.withLock { childCalls } }
    var childFeedback: String { lock.withLock { feedback.joined(separator: "\n") } }
    var returnedFeedback: String { lock.withLock { returnedToolFeedback.joined(separator: "\n") } }
    init(label: String, tool: String, input: [String: Any], gate: ChildMutationUserGate? = nil, readFullResult: Bool = false, parallelReads: Bool = false, directorySequence: Bool = false,
         finalOutput: String = "child finished") {
        self.directorySequence = directorySequence
        self.parallelReads = parallelReads
        childID = label + "-child"; effectTool = tool; self.input = input; self.gate = gate
        self.readFullResult = readFullResult
        self.finalOutput = finalOutput
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, tools: [],
            maxTokens: maxTokens, temperature: temperature)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        if parallelReads {
            let runtimeChild = AgentExecutionContext.current?.childToolRuntimeBinding?.boundary.identity.childTaskID
            let key = runtimeChild ?? "parent"
            let count = lock.withLock {
                parallelCounts[key, default: 0] += 1
                if runtimeChild != nil {
                    parallelFeedback[key] = messages.flatMap { message -> [String] in
                        if message.role == .tool { return [message.content] }
                        return message.toAgentContentParts().compactMap { part in
                            guard case .toolResult(_, _, let body, _, _, _, _, _) = part else { return nil }
                            return body
                        }
                    }.joined(separator: "\n")
                }
                return parallelCounts[key]!
            }
            if count == 1 {
                let name = runtimeChild == nil ? OrchestrationToolExecutor.toolName : effectTool
                let payload: [String: Any]
                if runtimeChild == nil {
                    let readRoot = URL(fileURLWithPath: input["path"] as? String ?? (input["command"] as! String).components(separatedBy: " ").last!).deletingLastPathComponent().path
                    payload = ["input_version": 2, "strategy": "parallel", "tasks": ["a", "b"].map { suffix in
                        ["id": childID + "-" + suffix, "title": childID + "-" + suffix,
                         "instructions": "read only the owned synthetic file once",
                         "required_capabilities": ["tools"], "allowed_tool_names": [effectTool],
                         "allowed_read_roots": [readRoot]] as [String: Any]
                    }]
                } else { payload = input }
                return LLMResponse(text: "", stopReason: "tool_calls", usage: nil, toolCalls: [
                    LLMToolCall(id: key + "-" + name, name: name,
                        rawArguments: String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self),
                        arguments: payload)])
            }
            return LLMResponse(text: "synthetic stream finished", stopReason: "stop", usage: nil)
        }
        let child = AgentExecutionContext.current?.childToolRuntimeBinding != nil
        let count = lock.withLock {
            returnedToolFeedback.append(contentsOf: messages.flatMap { message -> [String] in
                if message.role == .tool { return [message.content] }
                return message.toAgentContentParts().compactMap { part in
                    guard case .toolResult(_, _, let content, _, _, _, _, _) = part else { return nil }
                    return content
                }
            })
            if child {
                childCalls += 1
                if childCalls > 1 {
                    feedback.append(contentsOf: messages.flatMap { message -> [String] in
                        if message.role == .tool, message.toolCallID == childID + "-" + effectTool {
                            return [message.content]
                        }
                        return message.toAgentContentParts().compactMap { part in
                            guard case .toolResult(let id, _, let content, let isError, _, _, _, _) = part,
                                  id == childID + "-" + effectTool, !isError else { return nil }
                            return content
                        }
                    })
                }
                return childCalls
            }
            rootCalls += 1; return rootCalls
        }
        if directorySequence {
            if !child, count == 1 {
                let workspace = try #require(input["workspace_path"] as? String)
                let extra = try #require(input["path"] as? String)
                return try toolCall(name: OrchestrationToolExecutor.toolName, input: [
                    "input_version": 2, "strategy": "sequential", "tasks": [[
                        "id": childID, "title": childID, "instructions": "read only the three owned paths in order",
                        "required_capabilities": ["tools"], "allowed_tool_names": ["file_read"],
                        "allowed_read_roots": [URL(fileURLWithPath: workspace).deletingLastPathComponent().path,
                            URL(fileURLWithPath: extra).deletingLastPathComponent().path],
                        "working_directory": URL(fileURLWithPath: workspace).deletingLastPathComponent().path
                    ]]])
            }
            if child {
                let binding = try #require(AgentExecutionContext.current?.childToolRuntimeBinding)
                let generation = try #require(binding.boundary.identity.generationID)
                try #require(binding.boundary.identity.childTaskID == childID)
                let childIdentity = binding.boundary.identity
                var received: [String: (body: String, error: Bool)] = [:]
                for message in messages {
                    if message.role == .tool, let id = message.toolCallID,
                       id.hasPrefix(childID + "-n07-") {
                        // Native wire messages carry the body and call ID, not
                        // the legacy envelope's is_error. Use the same real
                        // child's unique terminal fact; never infer from text.
                        let ledger = try #require(AgentExecutionContext.current?.toolExecutionFactLedger)
                        let matching = ledger.facts.filter {
                            $0.toolCallID == id && $0.toolName == "file_read"
                                && $0.executionIdentity?.turn.sessionID == childIdentity.childSessionID
                                && $0.executionIdentity?.turn.turnID == childIdentity.cancelGeneration
                                && $0.executionIdentity?.turn.messageID == childIdentity.childTaskID
                                && $0.executionIdentity?.operationID == generation
                                && $0.attemptID == AgentToolExecutionAttemptID.canonical(
                                    executionIdentity: $0.executionIdentity,
                                    composerSnapshot: AgentExecutionContext.current?.composerSnapshot,
                                    childBoundary: binding.boundary)
                                && $0.attemptNumber == $0.executionIdentity?.attempt
                        }
                        try #require(matching.count == 1)
                        let fact = try #require(matching.first)
                        try #require(fact.status == .succeeded || fact.status == .failed)
                        received[id] = (message.content, fact.status == .failed)
                    } else {
                        for part in message.toAgentContentParts() {
                            if case .toolResult(let id, _, let body, let error, _, _, _, _) = part,
                               id.hasPrefix(childID + "-n07-") { received[id] = (body, error) }
                        }
                    }
                }
                lock.withLock {
                    if let original = directoryGeneration { directoryIdentityStable = directoryIdentityStable && original == generation }
                    else { directoryGeneration = generation }
                    directoryResults.merge(received) { _, latest in latest }
                }
                if count == 2 { await gate?.park() }
                let key: String
                let suffix: String
                switch count {
                case 1: key = "path"; suffix = "n07-before"
                case 2: key = "next_path"; suffix = "n07-after"
                case 3: key = "workspace_path"; suffix = "n07-workspace"
                default: return LLMResponse(text: "child finished", stopReason: "stop", usage: nil)
                }
                let path = try #require(input[key] as? String)
                return try toolCall(name: "file_read", input: ["path": path], suffix: suffix)
            }
            return LLMResponse(text: "parent finished", stopReason: "stop", usage: nil)
        }
        if count == 1 {
            if child { return try toolCall(name: effectTool, input: input) }
            await gate?.park()
            return try toolCall(name: OrchestrationToolExecutor.toolName, input: [
                "input_version": 2, "strategy": "sequential", "tasks": [[
                    "id": childID, "title": childID, "instructions": "perform the owned synthetic effect"]]
            ])
        }
        if !child, readFullResult, count == 2 {
            guard tools.contains(where: { $0.name == OrchestrationToolExecutor.resultToolName }),
                  let output = toolResult(OrchestrationToolExecutor.toolName, in: messages),
                  let payload = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
                  let rows = payload["results"] as? [[String: Any]],
                  let reference = rows.first?["output_ref"] as? [String: Any] else {
                throw ToolExecutorError.invalidParameter("child result output_ref")
            }
            return try toolCall(name: OrchestrationToolExecutor.resultToolName, input: reference)
        }
        if !child, readFullResult, count == 3 {
            let response = toolResult(OrchestrationToolExecutor.resultToolName, in: messages)
            lock.withLock { resultResponse = response }
        }
        return LLMResponse(text: child ? finalOutput : "parent finished", stopReason: "stop",
            usage: child && readFullResult ? LLMUsage(inputTokens: 11, outputTokens: 7) : nil)
    }
    private func toolResult(_ name: String, in messages: [LLMMessage]) -> String? {
        let callID = childID + "-" + name
        for message in messages {
            if message.role == .tool, message.toolCallID == callID { return message.content }
            for part in message.toAgentContentParts() {
                if case .toolResult(let id, _, let content, _, _, _, _, _) = part, id == callID {
                    return content
                }
            }
        }
        return nil
    }
    private func toolCall(name: String, input: [String: Any], suffix: String? = nil) throws -> LLMResponse {
        let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        return LLMResponse(text: "", stopReason: "tool_calls",
            usage: readFullResult && AgentExecutionContext.current?.childToolRuntimeBinding != nil
                ? LLMUsage(inputTokens: 5, outputTokens: 3) : nil, toolCalls: [
            LLMToolCall(id: childID + "-" + (suffix ?? name), name: name,
                rawArguments: String(decoding: data, as: UTF8.self), arguments: input)])
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("Goal18 child authority", .serialized)
@MainActor
struct Goal18ChildAuthorityTests {
    @Test("actual App child policy inherits four effect tools only from parent offer and owner")
    func inheritedChildPolicyIncludesParentEffectToolsAndFailsClosedWithoutOwner() throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let builtin = BuiltinToolExecutor(allowedRoot: profile.rootDirectory, deniedRoots: [])
        let tools: Set<String> = ["file_read", "file_write", "file_edit", "file_delete", "shell_execute"]
        let actual = BridgeStore.inheritedChildCapabilityPolicy(offeredToolNames: tools, builtinOwner: builtin)
        #expect(tools.allSatisfy { actual.allowsTool($0) })
        let narrowed = BridgeStore.inheritedChildCapabilityPolicy(offeredToolNames: ["file_read"], builtinOwner: builtin)
        #expect(narrowed.allowsTool("file_read"))
        #expect(!narrowed.allowsTool("file_write") && !narrowed.allowsTool("shell_execute"))
        let detached = BridgeStore.inheritedChildCapabilityPolicy(offeredToolNames: tools, builtinOwner: nil)
        #expect(tools.allSatisfy { !detached.allowsTool($0) })
        let unknown = BridgeStore.inheritedChildCapabilityPolicy(offeredToolNames: ["unknown-control", "mcp_unregistered"], builtinOwner: builtin)
        #expect(!unknown.allowsTool("unknown-control") && !unknown.allowsTool("mcp_unregistered"))
    }

    @Test("child live authority retains sibling lease rotation but rejects actual tightening")
    func inheritedChildLiveAuthoritySeparatesLeaseRotationFromRevocation() throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("child-authority-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "child-authority-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let chat = ChatStore(preferencesDefaults: defaults, logManager: LogManager(directory: root))
        let selection = ComposerPolicySelection(mode: .bypassPermission, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: true)
        chat.composerPolicySelection = selection
        let original = ComposerPolicyFactSource(knownCapabilities: ["file_write"], grantedCapabilities: ["file_write"],
            allowedWriteRoots: [root.path], workspaceID: chat.composerWorkspaceID, revision: "owned-rights",
            grantEpoch: "original-epoch", leaseID: "original-lease", expiresAt: Date().addingTimeInterval(60), autonomyCeiling: .l3)
        chat.configureComposerPolicy(original)
        #expect(chat.retainsInheritedChildAuthority(original, selection: selection))
        let sibling = ComposerPolicyFactSource(knownCapabilities: ["file_write"], grantedCapabilities: ["file_write"],
            allowedWriteRoots: [root.path], workspaceID: chat.composerWorkspaceID, revision: "owned-rights",
            grantEpoch: "sibling-epoch", leaseID: "sibling-lease", expiresAt: Date().addingTimeInterval(120), autonomyCeiling: .l3)
        chat.configureComposerPolicy(sibling)
        #expect(chat.retainsInheritedChildAuthority(original, selection: selection))
        let narrowed = ComposerPolicyFactSource(knownCapabilities: ["file_write"], grantedCapabilities: [],
            allowedWriteRoots: [], workspaceID: chat.composerWorkspaceID, revision: "owned-rights",
            grantEpoch: "sibling-epoch", leaseID: "sibling-lease", expiresAt: Date().addingTimeInterval(120), autonomyCeiling: .l1)
        chat.configureComposerPolicy(narrowed)
        #expect(!chat.retainsInheritedChildAuthority(original, selection: selection))
        chat.configureComposerPolicy(sibling)
        chat.composerPolicySelection = .init(mode: .plan, approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
        #expect(!chat.retainsInheritedChildAuthority(original, selection: selection))
        chat.composerPolicySelection = selection
        let expired = ComposerPolicyFactSource(knownCapabilities: ["file_write"], grantedCapabilities: ["file_write"],
            allowedWriteRoots: [root.path], workspaceID: chat.composerWorkspaceID, revision: "owned-rights",
            grantEpoch: "original-epoch", leaseID: "original-lease", expiresAt: .distantPast, autonomyCeiling: .l3)
        #expect(!chat.retainsInheritedChildAuthority(expired, selection: selection))
    }


    @Test("child mutation default migrates while preserving explicit selections")
    func childMutationSettingRoundTripAndLegacyDefaultPreserveOtherFields() throws {
        #expect(AgentSettings.default.childMutationsEnabled)
        let original = AgentSettings(maxLoopIterations: 7, toolTimeoutSeconds: 37,
            shellCommandTimeoutSeconds: 23, concurrentToolLimit: 1, fallbackEnabled: false,
            fileCheckpointsEnabled: false, childMutationsEnabled: true)
        let encoded = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(AgentSettings.self, from: encoded) == original)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "childMutationsEnabled")
        let decoded = try JSONDecoder().decode(AgentSettings.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        var expected = original
        expected.childMutationsEnabled = true
        #expect(decoded == expected)
    }

    @Test("N07 ordinary child keeps its frozen root custody and workspace when a directory is revoked")
    func ordinaryChildDirectoryRevocationFencesPreparedReadWithoutRevokingWorkspace() async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("n07-child-directory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let now = Date()
        try #require(readiness.upsert([ProviderReadinessPersistenceRecord(
            providerID: "goal18-child-switch-local", modelID: "goal18-child-switch-model",
            status: .passed, readinessState: .mock, checkedAt: now,
            evidenceID: "child-switch-owned-readiness", isApplied: true,
            discoveryReceiptID: "child-switch-owned-discovery", discoveredAt: now,
            applyReceiptID: "provider-readiness-apply:child-switch-owned", appliedAt: now)]))
        let center = SettingsCenter(settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("providers"), keychain: keychain),
            memoryStore: memory, sessionStore: sessions,
            logManager: LogManager(directory: root.appendingPathComponent("settings-logs")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")), providerReadinessStore: readiness)
        let suite = try #require(profile.userDefaultsSuiteName) + ".child-switch." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let bridge = try BridgeStore(taskStorePersistenceURL: root.appendingPathComponent("tasks.json"),
            preferencesDefaults: defaults, logManager: LogManager(directory: root.appendingPathComponent("logs")),
            sessionDocumentStore: SessionDocumentStore(directory: sessions.directory), sessionStore: sessions,
            memoryStore: memory, providerReadinessStore: readiness, canvasFeatureLane: .phase3NonCanvas)
        let approval = ChildMutationUserApproval()
        let frozenGate = ChildMutationUserGate()
        var directoryProvider: ChildMutationUserProvider?
        var witnessStarted = false
        var witnessFinished = false
        defer {
            Task { await frozenGate.open() }
            bridge.chat.stopAllStreamingForSafety()
            var writerJoined = !witnessStarted || witnessFinished
            if witnessStarted && !witnessFinished {
                do {
                    let provider = try #require(directoryProvider)
                    _ = try provider.finishDirectoryReaderWitness()
                    writerJoined = true
                } catch {
                    Issue.record("N07 owned writer did not join; retained root: \(root.path)")
                }
            }
            defaults.removePersistentDomain(forName: suite)
            if writerJoined { try? FileManager.default.removeItem(at: root) }
        }
        center.childMutationsEnabled = false // This case is read-only.
        center.maxLoopIterations = 6
        center.fallbackEnabled = false
        center.approvalPolicy = .riskOnlyAsk
        try #require(center.lastPersistenceError == nil)
        await bridge.attachProductionServices(agentSettings: center.settings.agent,
            fileAccessAllowedRoot: root, fileAccessDeniedRoots: [], sessionDirectory: sessions.directory,
            mcpManager: center.mcpManager, skillStore: center.skillStore,
            approvalDelegateOverride: approval, enableOrchestration: true, externalNetworkAllowed: true).value
        #expect(!center.childMutationsEnabled)

        let workspace = root.appendingPathComponent("workspace")
        let extra = root.appendingPathComponent("extra")
        for url in [workspace, extra] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let workspaceFile = workspace.appendingPathComponent("inside.txt")
        let extraFile = extra.appendingPathComponent("before.txt")
        let pipe = extra.appendingPathComponent("after.pipe")
        try "N07_WORKSPACE_STILL_ALLOWED".write(to: workspaceFile, atomically: true, encoding: .utf8)
        try "N07_EXTRA_READ_BEFORE_REVOKE".write(to: extraFile, atomically: true, encoding: .utf8)
        try #require(mkfifo(pipe.path, 0o600) == 0)
        let session = bridge.chat.applyNewSession(title: "N07 owned parent", workingDirectory: workspace.path)
        let handler = try #require(bridge.productionProjectSessionHandler)
        try handler.approveAdditionalDirectory(extra,
            identity: ProjectSessionGrantRegistry.directoryIdentity(extra), sessionID: session.uuidString,
            projectID: "session:\(session.uuidString)", workingDirectory: workspace.path, persistForProject: false)
        let provider = ChildMutationUserProvider(label: "n07-directory", tool: "file_read",
            input: ["path": extraFile.path, "next_path": pipe.path, "workspace_path": workspaceFile.path],
            gate: frozenGate, directorySequence: true)
        directoryProvider = provider
        bridge.chat.composerPolicySelection = .init(mode: .manual, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.draftText = "Delegate only the owned read sequence to one ordinary child."
        bridge.chat.submitComposer()
        let task = try #require(bridge.chat.turnTaskForTests(sessionID: session))
        let gateDeadline = Date().addingTimeInterval(30)
        while !(await frozenGate.entered) && Date() < gateDeadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(await frozenGate.entered)
        let binding = provider.directoryChildBinding
        try #require(binding.generation?.isEmpty == false && binding.stable)
        let before = try #require(provider.directoryToolResults[provider.childID + "-n07-before"])
        #expect(!before.error && before.body.contains("N07_EXTRA_READ_BEFORE_REVOKE"))
        witnessStarted = true
        try provider.startDirectoryReaderWitness()
        let row = try #require(bridge.approvalCenter.permissionDirectories?().first { $0.path == extra.path })
        let revoke = try #require(bridge.approvalCenter.revokePermissionDirectory)
        try revoke(row.id)
        await frozenGate.open()
        let terminalDeadline = Date().addingTimeInterval(30)
        while bridge.chat.turnTaskForTests(sessionID: session) != nil && Date() < terminalDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(bridge.chat.turnTaskForTests(sessionID: session) == nil)
        await task.value
        let readerOpened = try provider.finishDirectoryReaderWitness()
        witnessFinished = true
        #expect(!readerOpened)
        let after = try #require(provider.directoryToolResults[provider.childID + "-n07-after"])
        #expect(after.error && after.body.contains(ProjectSessionAppError.grantChanged.localizedDescription))
        let workspaceResult = try #require(provider.directoryToolResults[provider.childID + "-n07-workspace"])
        #expect(!workspaceResult.error && workspaceResult.body.contains("N07_WORKSPACE_STILL_ALLOWED"))
        #expect(provider.directoryChildBinding.generation == binding.generation && provider.directoryChildBinding.stable)
        #expect(await approval.observations.allSatisfy { $0.request.toolName != "file_read" })
    }

    @Test("user setting reaches actual cold and refreshed production child effects without granting parent authority")
    func userChildMutationSwitchReachesProductionFactoryAndFrozenTurns() async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("child-user-setting-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let now = Date()
        try #require(readiness.upsert([ProviderReadinessPersistenceRecord(
            providerID: "goal18-child-switch-local", modelID: "goal18-child-switch-model",
            status: .passed, readinessState: .mock, checkedAt: now,
            evidenceID: "child-switch-owned-readiness", isApplied: true,
            discoveryReceiptID: "child-switch-owned-discovery", discoveredAt: now,
            applyReceiptID: "provider-readiness-apply:child-switch-owned", appliedAt: now)]))
        let center = SettingsCenter(settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("providers"), keychain: keychain),
            memoryStore: memory, sessionStore: sessions,
            logManager: LogManager(directory: root.appendingPathComponent("settings-logs")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")), providerReadinessStore: readiness)
        let suite = try #require(profile.userDefaultsSuiteName) + ".child-switch." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let bridge = try BridgeStore(taskStorePersistenceURL: root.appendingPathComponent("tasks.json"),
            preferencesDefaults: defaults, logManager: LogManager(directory: root.appendingPathComponent("logs")),
            sessionDocumentStore: SessionDocumentStore(directory: sessions.directory), sessionStore: sessions,
            memoryStore: memory, providerReadinessStore: readiness, canvasFeatureLane: .phase3NonCanvas)
        let approval = ChildMutationUserApproval()
        let frozenGate = ChildMutationUserGate()
        defer {
            Task { await frozenGate.open() }
            bridge.chat.stopAllStreamingForSafety()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        center.childMutationsEnabled = false // Explicit opt-out remains a denial.
        center.maxLoopIterations = 4
        center.fallbackEnabled = false
        center.approvalPolicy = .riskOnlyAsk
        try #require(center.lastPersistenceError == nil)
        await bridge.attachProductionServices(agentSettings: center.settings.agent,
            fileAccessAllowedRoot: root, fileAccessDeniedRoots: [], sessionDirectory: sessions.directory,
            mcpManager: center.mcpManager, skillStore: center.skillStore,
            approvalDelegateOverride: approval, enableOrchestration: true, externalNetworkAllowed: true).value
        #expect(!center.childMutationsEnabled)
        let resultUsage = UsageStore(domain: .suite(suite))
        #expect(await resultUsage.waitForPersistence())
        bridge.chat.usageStore = resultUsage
        let projectHandler = try #require(bridge.productionProjectSessionHandler)
        let ownedProjectID = try projectHandler.authorizeFolderFromNativePicker(root)

        func start(_ provider: ChildMutationUserProvider, plan: Bool = false, projectID: String? = nil,
                   in selectedBridge: BridgeStore? = nil) throws -> (UUID, Task<Void, Never>) {
            let chat = (selectedBridge ?? bridge).chat
            let session = chat.applyNewSession(title: provider.childID, projectID: projectID,
                workingDirectory: projectID == nil ? nil : root.path)
            chat.composerPolicySelection = .init(mode: plan ? .plan : .manual,
                approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
            chat.streamingProviderOverride = provider
            chat.draftText = "delegate the owned synthetic child"
            chat.submitComposer()
            return (session, try #require(chat.turnTaskForTests(sessionID: session)))
        }
        func terminal(_ task: Task<Void, Never>, session: UUID, in selectedBridge: BridgeStore? = nil) async throws {
            let chat = (selectedBridge ?? bridge).chat
            let deadline = Date().addingTimeInterval(30)
            while chat.turnTaskForTests(sessionID: session) != nil && Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(chat.turnTaskForTests(sessionID: session) == nil)
            await task.value
        }
        func provider(_ label: String, tool: String = "file_write", gate: ChildMutationUserGate? = nil, readFullResult: Bool = false) -> ChildMutationUserProvider {
            ChildMutationUserProvider(label: label, tool: tool,
                input: tool == "file_write"
                    ? ["path": root.appendingPathComponent(label + ".txt").path, "content": "owned-child-bytes"]
                    // 只读命令按 PM-05 免问，这里加一个新建文件动作，保持“需要审批”的场景。
                    : ["command": "echo CHILD_COMMAND_PROOF && touch " + root.appendingPathComponent(label + ".marker").path,
                       "timeout": 10], gate: gate, readFullResult: readFullResult)
        }
        let off = provider("cold-off")
        let (offSession, offTask) = try start(off)
        try await terminal(offTask, session: offSession)
        #expect(off.childRequestCount > 0)
        let offRow = try #require(bridge.taskCenterControlConsumer.receiptRows().first { $0.taskID == off.childID })
        let offNavigation = try #require(bridge.taskCenterControlConsumer.resultNavigation(for: offRow))
        #expect(bridge.taskCenterControlConsumer.resultDetail(navigation: offNavigation)?.tokenUsage == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cold-off.txt").path))

        // The same user setter as the Toggle commits before the original App
        // onChange consumer refreshes the real engine. No builder is called here.
        center.childMutationsEnabled = true
        try #require(center.lastPersistenceError == nil)
        #expect(SettingsStore(directory: center.settingsStore.directory).settings.agent.childMutationsEnabled)
        bridge.refreshProductionAgentSettings(center.settings.agent)
        let on = provider("user-on", readFullResult: true)
        // Legacy task-ID-only usage must not contaminate this new attempt.
        resultUsage.recordTelemetry(.childUsage(origin: ChildUsageOrigin(taskID: on.childID),
            usage: LLMUsage(inputTokens: 900, outputTokens: 800),
            route: UsageServedRoute(provider: "synthetic", model: "legacy")))
        #expect(await resultUsage.waitForPersistence())
        let (onSession, onTask) = try start(on, projectID: ownedProjectID)
        try await terminal(onTask, session: onSession)
        try #require(FileManager.default.fileExists(atPath: root.appendingPathComponent("user-on.txt").path),
            Comment(rawValue: "Production ON write did not occur. Tool feedback: " + on.returnedFeedback))
        #expect(try String(contentsOf: root.appendingPathComponent("user-on.txt"), encoding: .utf8) == "owned-child-bytes")
        let writeApproval = try #require(await approval.observations.first {
            $0.request.toolName == "file_write" && $0.request.taskID == on.childID
        })
        #expect(writeApproval.approved)
        let activityRow = try #require(bridge.taskCenterControlConsumer.receiptRows().first { $0.taskID == on.childID })
        let activityProjection = TaskSummaryChildProjection(currentTaskID: activityRow.parentID,
            receiptRows: bridge.taskCenterControlConsumer.receiptRows())
        let visibleActivity = ChatChildTaskSummaryView.rowTitle(activityRow, projection: activityProjection)
        #expect(visibleActivity.contains("工具：file_write · 已请求 · 文件目标已隐藏，详见审批"))
        #expect(!visibleActivity.contains(root.path))
        let navigation = try #require(activityRow.childNavigation)
        try #require(navigation.locator != nil)
        #expect(navigation.parentSessionID == onSession.uuidString)
        #expect(activityProjection.allowsCurrentTaskNavigation(activityRow))
        let historical = TaskSummaryChildProjection(currentTaskID: nil,
            receiptRows: bridge.taskCenterControlConsumer.receiptRows(),
            viewerSessionID: onSession.uuidString)
        #expect(historical.rows == [activityRow])
        #expect(historical.completedCount == 1)
        #expect(historical.rows.first?.childNavigation == navigation)
        #expect(!historical.allowsCurrentTaskNavigation(activityRow))
        #expect(!activityRow.cancelAvailable)
        #expect(TaskSummaryChildProjection(currentTaskID: nil,
            receiptRows: bridge.taskCenterControlConsumer.receiptRows(),
            viewerSessionID: UUID().uuidString).rows.isEmpty)
        #expect(TaskSummaryChildProjection(currentTaskID: nil,
            receiptRows: bridge.taskCenterControlConsumer.receiptRows()).rows.isEmpty)
        #expect(TaskSummaryChildProjection(currentTaskID: "unrelated-current501",
            receiptRows: bridge.taskCenterControlConsumer.receiptRows(),
            viewerSessionID: onSession.uuidString).rows.isEmpty)
        let resultText = try #require(on.fullResultResponse)
        let resultPage = try #require(JSONSerialization.jsonObject(with: Data(resultText.utf8)) as? [String: Any])
        #expect(resultPage["content"] as? String == "child finished")
        #expect(resultPage["read_only"] as? Bool == true)
        let resultNavigation = try #require(bridge.taskCenterControlConsumer.resultNavigation(for: activityRow))
        let detail = try #require(bridge.taskCenterControlConsumer.resultDetail(navigation: resultNavigation))
        #expect(detail.tokenUsage == ChildResultTokenUsage(inputTokens: 16, outputTokens: 10, reportedCallCount: 2, totalInputTokens: 16))
        #expect(detail.settledToolCalls == 1)
        #expect(detail.artifactsComplete && detail.files.count == 1)
        let realFile = try #require(detail.files.first)
        #expect(realFile.displayName.hasSuffix("user-on.txt"))
        #expect(bridge.taskCenterControlConsumer.fileArtifactPresentationAuthorized(navigation: realFile,
            target: root.appendingPathComponent("user-on.txt")))
        let reportJSON = try #require(on.returnedFeedback.components(separatedBy: "\n").first(where: {
            $0.contains("\"output_ref\"") && $0.contains("\"results\"")
        }))
        let reportObject = try #require(JSONSerialization.jsonObject(with: Data(reportJSON.utf8)) as? [String: Any])
        let reportRows = try #require(reportObject["results"] as? [[String: Any]])
        let reported = try #require(reportRows.first)
        #expect(reported["settled_tool_calls"] as? Int == 1)
        #expect(reported["artifact_count"] as? Int == 1)
        #expect((reported["provider_reported_usage"] as? [String: Any])?["input"] as? Int == 16)
        let ownedLocator = try #require(navigation.locator)
        let foreignLocator = ChildTranscriptLocator(childSessionID: UUID().uuidString,
            parentSessionID: UUID().uuidString, taskID: ownedLocator.taskID,
            parentID: ownedLocator.parentID, runID: ownedLocator.runID,
            attemptID: ownedLocator.attemptID, childExecutionID: ownedLocator.childExecutionID,
            parentContextSnapshotID: ownedLocator.parentContextSnapshotID)
        #expect(await resultUsage.childTokenUsage(for: foreignLocator) == nil)
        let coldUsage = UsageStore(domain: .suite(suite))
        #expect(await coldUsage.waitForPersistence())
        #expect(await coldUsage.childTokenUsage(for: ownedLocator) == detail.tokenUsage)
        let sessionUsage = UsageFilteredSettingsView.sessionRecords(from: coldUsage, sessionID: ownedLocator.parentSessionID)
        let realChildUsage = sessionUsage.filter { $0.attribution?.childTranscriptLocator == ownedLocator }
        #expect(realChildUsage.count == 2 && realChildUsage.allSatisfy { $0.sessionID == ownedLocator.parentSessionID })
        let sessionTokens = sessionUsage.reduce(0) { $0 + $1.totalTokens }
        #expect(sessionTokens >= 26 && UsageFilteredSettingsView.childTokenShare(records: sessionUsage) == Double(26) / Double(sessionTokens))
        #expect(UsageFilteredSettingsView.sessionRecords(from: coldUsage, sessionID: foreignLocator.parentSessionID).isEmpty)

        #expect(await approval.observations.allSatisfy { $0.request.toolName != OrchestrationToolExecutor.resultToolName })

        let longAnswer = String(repeating: "已核对合成资料并记录结果。下一步请复核产物后继续。", count: 120)
        let longProvider = ChildMutationUserProvider(label: "long-result", tool: "file_write",
            input: ["path": root.appendingPathComponent("long-result.txt").path, "content": "owned-long-result"],
            readFullResult: true, finalOutput: longAnswer)
        let (longSession, longTask) = try start(longProvider, projectID: ownedProjectID)
        try await terminal(longTask, session: longSession)
        let longReportLine = try #require(longProvider.returnedFeedback.components(separatedBy: "\n").first {
            $0.contains("\"results\"") && $0.contains("\"output_ref\"")
        })
        let longObject = try #require(JSONSerialization.jsonObject(with: Data(longReportLine.utf8)) as? [String: Any])
        let longRows = try #require(longObject["results"] as? [[String: Any]])
        let longRow = try #require(longRows.first)
        let longSummary = try #require(longRow["summary"] as? String)
        #expect(longAnswer.utf8.count > 5_120)
        #expect(longSummary.utf8.count >= 1_024 && longSummary.utf8.count <= 3_072)
        #expect(longSummary.hasSuffix("。\n可用 child_result 取全文。"))
        let longRaw = try #require(longProvider.fullResultResponse)
        let longPage = try #require(JSONSerialization.jsonObject(with: Data(longRaw.utf8)) as? [String: Any])
        #expect(longPage["content"] as? String == longAnswer)
        #expect(longPage["next_offset"] is NSNull)
        #expect(try String(contentsOf: root.appendingPathComponent("long-result.txt"), encoding: .utf8) == "owned-long-result")

        await approval.setDenyChild(true)
        let denied = provider("parent-denied")
        let (deniedSession, deniedTask) = try start(denied)
        try await terminal(deniedTask, session: deniedSession)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("parent-denied.txt").path))
        let denial = try #require(await approval.observations.first { $0.request.taskID == denied.childID })
        #expect(!denial.approved)
        await approval.setDenyChild(false)
        let plan = provider("parent-plan")
        let (planSession, planTask) = try start(plan, plan: true)
        try await terminal(planTask, session: planSession)
        #expect(plan.childRequestCount == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("parent-plan.txt").path))

        let command = provider("user-command", tool: "shell_execute")
        let (commandSession, commandTask) = try start(command)
        try await terminal(commandTask, session: commandSession)
        #expect(command.childFeedback.contains("CHILD_COMMAND_PROOF"))
        #expect(await approval.observations.contains {
            $0.request.taskID == command.childID && $0.request.toolName == "shell_execute" && $0.approved
        })

        let frozen = provider("frozen-on", gate: frozenGate)
        let (frozenSession, frozenTask) = try start(frozen)
        let enteredDeadline = Date().addingTimeInterval(30)
        while !(await frozenGate.entered) && Date() < enteredDeadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(await frozenGate.entered)
        center.childMutationsEnabled = false
        try #require(center.lastPersistenceError == nil)
        bridge.refreshProductionAgentSettings(center.settings.agent)
        await frozenGate.open()
        try await terminal(frozenTask, session: frozenSession)
        #expect(try String(contentsOf: root.appendingPathComponent("frozen-on.txt"), encoding: .utf8) == "owned-child-bytes")
        let newOff = provider("new-off")
        let (newOffSession, newOffTask) = try start(newOff)
        try await terminal(newOffTask, session: newOffSession)
        #expect(newOff.childRequestCount > 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("new-off.txt").path))
        #expect(!SettingsStore(directory: center.settingsStore.directory).settings.agent.childMutationsEnabled)

        // A second real cold factory consumes the persisted ON value, without
        // the hot refresh seam or an engine builder in the test.
        center.childMutationsEnabled = true
        try #require(center.lastPersistenceError == nil)
        let persistedOn = SettingsStore(directory: center.settingsStore.directory).settings.agent
        // A cold App opens this user's persisted sessions with the matching
        // SettingsCenter, rather than mixing two different profile roots.
        let coldSessions = SessionStore(directory: sessions.directory)
        let coldOnBridge = try BridgeStore(taskStorePersistenceURL: root.appendingPathComponent("cold-on-tasks.json"),
            preferencesDefaults: defaults, logManager: LogManager(directory: root.appendingPathComponent("cold-on-logs")),
            sessionDocumentStore: SessionDocumentStore(directory: coldSessions.directory), sessionStore: coldSessions,
            memoryStore: memory, providerReadinessStore: readiness, canvasFeatureLane: .phase3NonCanvas)
        defer { coldOnBridge.chat.stopAllStreamingForSafety() }
        await coldOnBridge.attachProductionServices(agentSettings: persistedOn,
            fileAccessAllowedRoot: root, fileAccessDeniedRoots: [], sessionDirectory: coldSessions.directory,
            mcpManager: center.mcpManager, skillStore: center.skillStore,
            approvalDelegateOverride: approval, enableOrchestration: true, externalNetworkAllowed: true).value
        let coldOn = provider("cold-user-on")
        let (coldOnSession, coldOnTask) = try start(coldOn, in: coldOnBridge)
        try await terminal(coldOnTask, session: coldOnSession, in: coldOnBridge)
        try #require(FileManager.default.fileExists(atPath: root.appendingPathComponent("cold-user-on.txt").path),
            Comment(rawValue: "Persisted ON cold-factory write did not occur. Child requests: \(coldOn.childRequestCount). Tool feedback: "
                + coldOn.returnedFeedback + " Chat: "
                + coldOnBridge.chat.messages.filter { $0.role == .assistant }.map(\.content).joined(separator: "\n")))
        #expect(try String(contentsOf: root.appendingPathComponent("cold-user-on.txt"), encoding: .utf8) == "owned-child-bytes")

    }

}

// Uses the existing production Composer/orchestrator fixture. Only provider
// replies and explicit user button decisions are scripted; requests, canonical
// child bindings, approval gates, App queue, and file reads are production.
extension Goal18ChildAuthorityTests {
    @Test(arguments: ["approve", "deny", "cancel", "expire"])
    func parallelChildApprovalsKeepIndependentRequestsThroughProductionQueue(_ action: String) async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("child-queue-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 对齐 Claude Code：授权目录内的只读文件工具不再弹审批卡，所以两个子任务改用仍逐次审批的
        // shell_execute（cat 读同一个文件），用来验证并行审批队列。
        let file = root.appendingPathComponent("owned.txt")
        let bytes = Data("CHILD_QUEUE_OWNED_BYTES\n".utf8)
        try bytes.write(to: file)
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let now = Date()
        try #require(readiness.upsert([ProviderReadinessPersistenceRecord(
            providerID: "goal18-child-switch-local", modelID: "goal18-child-switch-model",
            status: .passed, readinessState: .mock, checkedAt: now,
            evidenceID: "child-queue-owned", isApplied: true,
            discoveryReceiptID: "child-queue-discovery", discoveredAt: now,
            applyReceiptID: "provider-readiness-apply:child-queue", appliedAt: now)]))
        let settings = SettingsCenter(settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("providers"), keychain: keychain),
            memoryStore: memory, sessionStore: sessions,
            logManager: LogManager(directory: root.appendingPathComponent("settings-logs")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")), providerReadinessStore: readiness)
        let suite = try #require(profile.userDefaultsSuiteName) + ".child-queue." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let bridge = try BridgeStore(taskStorePersistenceURL: root.appendingPathComponent("tasks.json"),
            preferencesDefaults: defaults, logManager: LogManager(directory: root.appendingPathComponent("logs")),
            sessionDocumentStore: SessionDocumentStore(directory: sessions.directory), sessionStore: sessions,
            memoryStore: memory, providerReadinessStore: readiness, canvasFeatureLane: .phase3NonCanvas)
        let approval = ChildQueueUserDelegate(center: bridge.approvalCenter)
        defer {
            bridge.chat.stopAllStreamingForSafety()
            bridge.approvalCenter.stopGeneration()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        settings.childMutationsEnabled = true
        settings.maxLoopIterations = 4
        settings.fallbackEnabled = false
        settings.approvalPolicy = .alwaysAsk
        await bridge.attachProductionServices(agentSettings: settings.settings.agent,
            fileAccessAllowedRoot: root, fileAccessDeniedRoots: [], sessionDirectory: sessions.directory,
            mcpManager: settings.mcpManager, skillStore: settings.skillStore,
            approvalDelegateOverride: approval, enableOrchestration: true,
            childConcurrencySelection: try ChildConcurrencySelection(userSelected: 2, recommended: 2, effective: 2),
            externalNetworkAllowed: true).value
        let provider = ChildMutationUserProvider(label: "queue-" + action, tool: "shell_execute",
            input: ["command": "cat " + file.path + " && touch " + root.appendingPathComponent("queue-marker").path,
                    "timeout": 10], parallelReads: true)
        let session = bridge.chat.applyNewSession(title: "parallel owned approval queue")
        bridge.chat.composerPolicySelection = .init(mode: .manual, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.draftText = "delegate the owned synthetic reads"
        bridge.chat.submitComposer()
        let parentTask = try #require(bridge.chat.turnTaskForTests(sessionID: session))
        func wait(_ predicate: () -> Bool, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(10)
            while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(predicate(), Comment(rawValue: "wait@\(line) pending=\(bridge.approvalCenter.pendingRequest?.toolName ?? "nil") queued=\(bridge.approvalCenter.approvalQueue.queuedRequests.map(\.toolName)) streaming=\(bridge.chat.isStreaming) approvals=[\(approval.debugSummary)] feedback=\(provider.parallelToolFeedback)"))
        }
        // The parent orchestrate request also receives its own explicit user
        // decision. The fixture never approves a child on the parent's behalf.
        try await wait { bridge.approvalCenter.pendingRequest != nil }
        let parent = try #require(bridge.approvalCenter.pendingRequest)
        #expect(parent.toolName == OrchestrationToolExecutor.toolName)
        bridge.approvalCenter.resolve(approved: true, confirmed: true, requestID: parent.requestID)
        try await wait { bridge.approvalCenter.pendingRequest?.source != nil
            && bridge.approvalCenter.approvalQueue.queuedRequests.count == 1 }
        let first = try #require(bridge.approvalCenter.pendingRequest)
        let second = try #require(bridge.approvalCenter.approvalQueue.queuedRequests.first)
        #expect(first.toolName == "shell_execute" && second.toolName == "shell_execute")
        #expect(first.taskID != second.taskID && first.sessionID != second.sessionID)
        #expect(first.identityDigest != second.identityDigest && first.requestID != second.requestID)
        // This is the real Composer-specific branch admitted by Core, not
        // fabricated legacy bound requests standing in for production.
        #expect(first.binding == nil && second.binding == nil)
        #expect(first.composerMode == "manual" && second.composerMode == "manual")
        let navigationConsumer = bridge.taskCenterControlConsumer
        let firstRow = try #require(navigationConsumer.receiptRows().first { $0.taskID == first.taskID })
        let firstNavigation = try #require(navigationConsumer.approvalNavigation(
            for: firstRow, pendingRequest: bridge.approvalCenter.pendingRequest))
        #expect(firstNavigation.sessionID == first.sessionID)
        #expect(firstNavigation.identityDigest == first.identityDigest)
        #expect(navigationConsumer.pendingApproval(navigation: firstNavigation,
            pendingRequest: bridge.approvalCenter.pendingRequest) == first)
        let approvalCenter = bridge.approvalCenter
        let secondPendingRow = try #require(navigationConsumer.receiptRows().first { $0.taskID == second.taskID })
        let secondPendingNavigation = try #require(navigationConsumer.approvalNavigation(
            for: secondPendingRow, pendingRequest: second))
        let navigationEvents = bridge.agentTaskStore.events(runID: firstNavigation.runID)
        let presentedActions = approvalCenter.actionsForPresentedRequest()
        #expect(!presentedActions.viewTaskCenter(secondPendingNavigation, navigationConsumer))
        #expect(presentedActions.viewTaskCenter(firstNavigation, navigationConsumer))
        #expect(approvalCenter.isPresentationSuspended)
        #expect(!approvalCenter.isPromptPresented)
        #expect(approvalCenter.pendingRequest == first)
        #expect(approvalCenter.approvalQueue.queuedRequests == [second])
        presentedActions.dismiss()
        presentedActions.deny()
        #expect(approvalCenter.pendingRequest == first)
        #expect(approval.decision(first.requestID) == nil)
        #expect(!approvalCenter.requestTaskCenterResume(secondPendingNavigation, consumer: navigationConsumer))
        #expect(approvalCenter.requestTaskCenterResume(firstNavigation, consumer: navigationConsumer))
        let resumeIntent = try #require(approvalCenter.taskCenterResumeIntent)
        #expect(approvalCenter.resumeFromTaskCenter(resumeIntent, consumer: navigationConsumer))
        #expect(!approvalCenter.isPresentationSuspended && approvalCenter.isPromptPresented)
        #expect(approvalCenter.pendingRequest == first)
        #expect(approvalCenter.pendingRequest?.callID == first.callID)
        #expect(approvalCenter.pendingRequest?.inputDigest == first.inputDigest)
        #expect(bridge.agentTaskStore.events(runID: firstNavigation.runID) == navigationEvents)
        // The old rendered card cannot settle the resumed original request.
        presentedActions.deny()
        #expect(!presentedActions.viewTaskCenter(firstNavigation, navigationConsumer))
        #expect(approvalCenter.pendingRequest == first)
        #expect(approval.decision(first.requestID) == nil)
        // The other genuine child cannot borrow this row's navigation.
        #expect(navigationConsumer.approvalNavigation(for: firstRow, pendingRequest: second) == nil)
        var forged = ApprovalRequest(id: first.id, requestID: first.requestID, callID: first.callID,
            toolName: first.toolName, inputSummary: "redacted", riskLevel: first.riskLevel,
            requiresApproval: true, sessionID: first.sessionID, taskID: first.taskID,
            composerMode: first.composerMode, identityDigest: "synthetic-foreign-digest")
        forged.source = first.source
        #expect(navigationConsumer.approvalNavigation(for: firstRow, pendingRequest: forged) == nil)
        forged = first
        forged.source = .childTask(taskID: try #require(first.taskID), parentID: "synthetic-foreign-parent")
        #expect(navigationConsumer.approvalNavigation(for: firstRow, pendingRequest: forged) == nil)
        forged = ApprovalRequest(id: first.id, requestID: first.requestID, callID: first.callID,
            toolName: first.toolName, inputSummary: "redacted", riskLevel: first.riskLevel,
            requiresApproval: true, sessionID: first.sessionID, taskID: first.taskID,
            identityDigest: first.identityDigest)
        forged.source = first.source
        #expect(navigationConsumer.approvalNavigation(for: firstRow, pendingRequest: forged) == nil)
        #expect(approval.origin(first.requestID) == .interactive && approval.origin(second.requestID) == .interactive)
        #expect(provider.parallelToolFeedback.values.allSatisfy { !$0.contains("CHILD_QUEUE_OWNED_BYTES") })
        #expect(approval.decision(first.requestID) == nil && approval.decision(second.requestID) == nil)
        // Replay the *actual* production request with its captured runtime,
        // not a fabricated child DTO. Same-child duplication must not enter.
        let duplicate = await approval.duplicate(second.requestID)
        #expect(!duplicate.approved && duplicate.reason == "已有审批请求在处理中")
        #expect(bridge.approvalCenter.pendingRequest == first)
        #expect(bridge.approvalCenter.approvalQueue.queuedRequests == [second])
        if action == "cancel" {
            approval.cancel(second.requestID)
            try await wait { bridge.approvalCenter.approvalQueue.queuedRequests.isEmpty }
            #expect(bridge.approvalCenter.pendingRequest == first)
            try await wait { approval.decision(second.requestID) != nil }
            #expect(approval.decision(second.requestID)?.status == .cancelled)
            bridge.approvalCenter.resolve(approved: true, confirmed: true, requestID: first.requestID)
        } else {
            if action == "expire" { bridge.approvalCenter.expirationInterval = 0.05 }
            bridge.approvalCenter.resolve(approved: action != "deny", confirmed: action != "deny",
                requestID: first.requestID)
            if action == "expire" {
                try await wait { approval.decision(second.requestID) != nil }
                #expect(approval.decision(second.requestID)?.status == .expired)
            } else {
                try await wait { bridge.approvalCenter.pendingRequest?.requestID == second.requestID }
                #expect(bridge.approvalCenter.pendingRequest == second)
                let secondRow = try #require(navigationConsumer.receiptRows().first { $0.taskID == second.taskID })
                let secondNavigation = try #require(navigationConsumer.approvalNavigation(
                    for: secondRow, pendingRequest: bridge.approvalCenter.pendingRequest))
                #expect(secondNavigation.sessionID == second.sessionID)
                #expect(secondNavigation.requestID == second.requestID)
                #expect(navigationConsumer.pendingApproval(navigation: firstNavigation,
                    pendingRequest: bridge.approvalCenter.pendingRequest) == nil)
                #expect(approval.decision(second.requestID) == nil)
                #expect(!provider.parallelToolFeedback[try #require(second.taskID), default: ""].contains("CHILD_QUEUE_OWNED_BYTES"))
                bridge.approvalCenter.resolve(approved: true, confirmed: true, requestID: second.requestID)
            }
        }
        try await wait { bridge.chat.turnTaskForTests(sessionID: session) == nil }
        await parentTask.value
        #expect(navigationConsumer.approvalNavigation(for: firstRow, pendingRequest: first) == nil)
        #expect(navigationConsumer.pendingApproval(navigation: firstNavigation, pendingRequest: first) == nil)
        let firstFeedback = provider.parallelToolFeedback[try #require(first.taskID), default: ""]
        let secondFeedback = provider.parallelToolFeedback[try #require(second.taskID), default: ""]
        #expect(firstFeedback.contains("CHILD_QUEUE_OWNED_BYTES") == (action != "deny"))
        #expect(secondFeedback.contains("CHILD_QUEUE_OWNED_BYTES") == (action == "approve" || action == "deny"))
        for request in [first, second] {
            let decision = try #require(approval.decision(request.requestID))
            #expect(decision.requestID == request.requestID)
            #expect(decision.bindingDigest == request.identityDigest)
        }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(bridge.approvalCenter.pendingRequest == nil)
        #expect(bridge.approvalCenter.approvalQueue.queuedRequests.isEmpty)
    }
}

// Controlled external Provider seam: the real Bridge/orchestrator supplies the
// thinking level; the existing production request-body mapper applies it.
private final class ChildCeilingRequestProvider: AssistantStreamingLLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "G22_CHILD_CEILING"
    var model = LLMModel(id: "deepseek-flash", displayName: "Owned child ceiling", provider: "G22_CHILD_CEILING")
    let capabilities: Set<ProviderCapability> = [.tools, .streaming]
    var runtimeConfigurationMaterial: String? = "owned-child-ceiling-v1"
    let label: String
    let stableModelID: String
    let gate: ChildMutationUserGate?
    private let lock = NSLock()
    private var parentCalls = 0
    private var levels: [String: ThinkingLevel] = [:]
    private var efforts: [String: String] = [:]
    private var switches: [String: String] = [:]
    var appliedLevels: [String: ThinkingLevel] { lock.withLock { levels } }
    var appliedEfforts: [String: String] { lock.withLock { efforts } }
    var appliedSwitches: [String: String] { lock.withLock { switches } }
    init(label: String, stableModelID: String, gate: ChildMutationUserGate? = nil) {
        self.label = label; self.stableModelID = stableModelID; self.gate = gate
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, tools: [],
            maxTokens: maxTokens, temperature: temperature)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        let count = lock.withLock { parentCalls += 1; return parentCalls }
        guard count == 1 else { return LLMResponse(text: "parent complete", stopReason: "stop", usage: nil) }
        let input: [String: Any] = ["input_version": 2, "strategy": "sequential", "tasks": ["ultra", "off"].map { level in
            ["id": label + "-" + level, "title": label + "-" + level,
             "instructions": "return an owned synthetic completion", "model": stableModelID,
             "thinking_level": level, "required_capabilities": ["streaming"],
             "allowed_tool_names": [], "allowed_read_roots": []] as [String: Any]
        }]
        let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        return LLMResponse(text: "", stopReason: "tool_calls", usage: nil,
            toolCalls: [LLMToolCall(id: label + "-orchestrate", name: OrchestrationToolExecutor.toolName,
                rawArguments: String(decoding: data, as: UTF8.self), arguments: input)])
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func streamAssistantMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                                maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        try await streamAssistantMessage(messages: messages, systemPrompt: systemPrompt, tools: tools,
            maxTokens: maxTokens, temperature: temperature, thinkingLevel: nil)
    }
    func streamAssistantMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                                maxTokens: Int, temperature: Double?, thinkingLevel: ThinkingLevel?) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        if let child = AgentExecutionContext.current?.childToolRuntimeBinding?.boundary.identity.childTaskID {
            let level = try #require(thinkingLevel)
            var body: [String: Any] = [:]
            let application = AssistantThinkingParameters.apply(level, modelID: model.id, wire: .openAIChat, body: &body)
            try #require(application == .written)
            lock.withLock {
                levels[child] = level
                efforts[child] = body["reasoning_effort"] as? String
                switches[child] = (body["thinking"] as? [String: String])?["type"]
            }
            if child.hasSuffix("-ultra") { await gate?.park() }
            return llmAssistantCompletedStream(LLMResponse(text: "owned child complete", stopReason: "stop", usage: nil))
        }
        return llmAssistantCompletedStream(try await sendMessage(messages: messages, systemPrompt: systemPrompt,
            tools: tools, maxTokens: maxTokens, temperature: temperature))
    }
}


extension Goal18ChildAuthorityTests {
    @Test func changedChildSettingsReachNewProductionRoundsAndPreserveFrozenTasks() async throws {
        try await B1TaskOriginalFixtureSupport.withRoot("child-ceiling-refresh") { root async throws -> Void in
            let suite = "child-ceiling-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let keychain = KeychainStore(backing: InMemoryKeychainBacking())
            let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
            let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
            let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
            let now = Date()
            try #require(readiness.upsert([ProviderReadinessPersistenceRecord(
                providerID: "G22_CHILD_CEILING", modelID: "deepseek-flash", status: .passed,
                readinessState: .mock, checkedAt: now, evidenceID: "owned-child-ceiling",
                isApplied: true, discoveryReceiptID: "owned-child-discovery", discoveredAt: now,
                applyReceiptID: "provider-readiness-apply:owned-child-ceiling", appliedAt: now)]))
            let center = SettingsCenter(settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
                envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain),
                memoryStore: memory, sessionStore: sessions,
                logManager: LogManager(directory: root.appendingPathComponent("logs")),
                mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
                skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")), providerReadinessStore: readiness)
            center.childModelOverridesEnabled = true
            center.childModelThinkingLevelCeiling = nil
            center.maxLoopIterations = 4
            center.fallbackEnabled = false
            let bridge = try BridgeStore(taskStorePersistenceURL: root.appendingPathComponent("tasks.json"),
                preferencesDefaults: defaults, logManager: LogManager(directory: root.appendingPathComponent("bridge-logs")),
                sessionDocumentStore: SessionDocumentStore(directory: sessions.directory), sessionStore: sessions,
                memoryStore: memory, providerReadinessStore: readiness, canvasFeatureLane: .phase3NonCanvas)
            defer { bridge.chat.stopAllStreamingForSafety() }
            await bridge.attachProductionServices(agentSettings: center.settings.agent,
                fileAccessAllowedRoot: root, fileAccessDeniedRoots: [], sessionDirectory: sessions.directory,
                mcpManager: center.mcpManager, skillStore: center.skillStore,
                approvalDelegateOverride: ChildMutationUserApproval(), enableOrchestration: true,
                externalNetworkAllowed: true).value
            let record = EnvVarEntry(name: "G22_CHILD_CEILING", value: "owned-synthetic", isSecret: false,
                baseURL: "https://child-ceiling.example.test/v1", modelNames: ["deepseek-flash"])
            bridge.chat.providerRecordsSource = { [record] }
            let item = try #require(bridge.chat.chatModelPickerItems.first { $0.modelID == "deepseek-flash" })
            @MainActor func start(_ provider: ChildCeilingRequestProvider) throws -> Task<Void, Never> {
                let session = bridge.chat.applyNewSession(title: provider.label)
                bridge.chat.streamingProviderOverride = provider
                bridge.chat.composerPolicySelection = .init(mode: .manual, approvalScope: .request,
                    effort: .standard, bypassModeConfirmed: false)
                bridge.chat.draftText = "delegate the two owned synthetic text tasks"
                bridge.chat.submitComposer()
                return try #require(bridge.chat.turnTaskForTests(sessionID: session))
            }
            let gate = ChildMutationUserGate()
            let frozen = ChildCeilingRequestProvider(label: "frozen", stableModelID: item.id, gate: gate)
            let firstTurn = try start(frozen)
            let deadline = Date().addingTimeInterval(10)
            while !(await gate.entered) && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            let entered = await gate.entered
            if !entered { await gate.open() }
            try #require(entered, "The real first child must enter parameter application before the settings change")
            center.childModelThinkingLevelCeiling = .low
            bridge.refreshProductionAgentSettings(center.settings.agent)
            await gate.open()
            await firstTurn.value
            #expect(frozen.appliedLevels["frozen-ultra"] == .xhigh)
            #expect(frozen.appliedLevels["frozen-off"] == .off)
            let low = ChildCeilingRequestProvider(label: "low", stableModelID: item.id)
            await (try start(low)).value
            #expect(low.appliedLevels == ["low-ultra": .low, "low-off": .off])
            #expect(low.appliedEfforts["low-ultra"] == "low")
            #expect(low.appliedSwitches["low-off"] == "disabled")
            center.childModelThinkingLevelCeiling = .off
            bridge.refreshProductionAgentSettings(center.settings.agent)
            let offCeiling = ChildCeilingRequestProvider(label: "off-ceiling", stableModelID: item.id)
            await (try start(offCeiling)).value
            #expect(offCeiling.appliedLevels == ["off-ceiling-ultra": .off, "off-ceiling-off": .off])
            #expect(offCeiling.appliedSwitches == ["off-ceiling-ultra": "disabled", "off-ceiling-off": "disabled"])
            center.childModelThinkingLevelCeiling = nil
            bridge.refreshProductionAgentSettings(center.settings.agent)
            let restored = ChildCeilingRequestProvider(label: "restored", stableModelID: item.id)
            await (try start(restored)).value
            #expect(restored.appliedLevels == ["restored-ultra": .xhigh, "restored-off": .off])
            #expect(restored.appliedEfforts["restored-ultra"] == "high")
            #expect(frozen.appliedLevels["frozen-ultra"] == .xhigh)
            center.childModelOverridesEnabled = false
            bridge.refreshProductionAgentSettings(center.settings.agent)
            let disabled = ChildCeilingRequestProvider(label: "disabled", stableModelID: item.id)
            await (try start(disabled)).value
            #expect(disabled.appliedLevels.isEmpty)
            #expect(bridge.chat.messages.contains { $0.role == .tool && $0.content.contains("未授权子任务使用其他模型和思考档位") })
            // Pair the runtime refresh consumer with its actual AppRoot subscriptions.
            var sourceURL = URL(fileURLWithPath: #filePath)
            for _ in 0..<5 { sourceURL.deleteLastPathComponent() }
            let app = try String(contentsOf: sourceURL.appendingPathComponent("src/MinisCanvasApp/Sources/MinisCanvasApp/MinisCanvasApp.swift"), encoding: .utf8)
            for setting in ["childModelOverridesEnabled", "childModelThinkingLevelCeiling"] {
                let hook = ".onChange(of: settingsCenter." + setting + ") { _, _ in\n                    bridge.refreshProductionAgentSettings(settingsCenter.settings.agent)"
                #expect(app.contains(hook))
            }
        }
    }
}
