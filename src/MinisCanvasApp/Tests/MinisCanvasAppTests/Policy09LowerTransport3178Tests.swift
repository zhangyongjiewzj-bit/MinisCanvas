import Darwin
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

private actor Policy09PreparationGate3178 {
    private(set) var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}


/// Records actual lower Builtin browser dispatch. It has no policy, budget or
/// approval decision and performs no network or GUI operation.
private final class Policy09LowerTransport3178: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    var calls: [String] { lock.withLock { names } }
    func execute(name: String, input: [String: Any]) async throws -> String {
        lock.withLock { names.append(name) }
        return try BrowserToolResponse(outcome: "succeeded", action: "navigate", scopeID: "owned3178-scope",
            result: "owned3178-browser-transport-result").encoded()
    }
}
private actor Policy09DenyApproval3178: ApprovalDelegate {
    private(set) var requests: [ApprovalRequest] = []
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        return ApprovalDecision(approved: false, reason: "owned3178 denied",
            confirmed: false, requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}
private final class Policy09Provider3178: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "policy3178-local"
    let capabilities: Set<ProviderCapability> = [.tools]
    private let lock = NSLock()
    private var value = LLMModel(id: "policy3178", displayName: "Owned refusal observer", provider: "policy3178-local",
                                contextWindow: 32_768, maxOutputTokens: 16_384)
    private var material: String? = "owned3178-synthetic"
    private var histories: [[LLMMessage]] = []
    private var observedChildTaskIDs: [String] = []
    var model: LLMModel { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    var runtimeConfigurationMaterial: String? { get { lock.withLock { material } } set { lock.withLock { material = newValue } } }
    var requests: [[LLMMessage]] { lock.withLock { histories } }
    var childTaskIDs: [String] { lock.withLock { observedChildTaskIDs } }
    let callID: String
    private let returnsToolCall: Bool
    private let action: String
    private let url: String
    init(callID: String, returnsToolCall: Bool = true, action: String = "navigate",
         url: String = "https://allowed.example.com/owned3178") {
        self.url = url
        self.callID = callID
        self.returnsToolCall = returnsToolCall
        self.action = action
    }
    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                                            temperature: Double?) async throws -> LLMResponse {
        let childTaskID = UsageTelemetryContext.childOrigin?.taskID
        let index = lock.withLock {
            histories.append(messages)
            if let childTaskID { observedChildTaskIDs.append(childTaskID) }
            return histories.count
        }
        guard returnsToolCall && index == 1 else {
            return LLMResponse(text: "owned3178 tool result received", stopReason: "stop", usage: nil)
        }
        var arguments: [String: Any] = ["tool_title": "Owned mode boundary", "action": action, "url": url]
        if action == "click" { arguments["selector"] = "#owned3178" }
        // This consumer observes the production legacy tool_result envelope's
        // explicit is_error. Native tool-role wire has no such field. Supply the
        // real supported text-call format rather than interpreting native text
        // as a legacy envelope or synthesizing an error bit from missing facts.
        let envelope: [String: Any] = ["tool_calls": [["id": callID, "name": "browser", "input": arguments]]]
        let raw = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        return LLMResponse(text: String(decoding: raw, as: UTF8.self), stopReason: "tool_calls", usage: nil)
    }
    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                                            maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
    }
    nonisolated(nonsending) func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                                              temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw CancellationError()
    }
}
// Original ProductionPolicyWiring observation traversal, with no replacement
// budget factory or executor authorization wrapper.
private func actualBuiltin3178(_ executor: any ToolExecutor) -> BuiltinToolExecutor? {
    if let builtin = executor as? BuiltinToolExecutor { return builtin }
    if let concurrent = executor as? ConcurrentToolLimitingExecutor { return actualBuiltin3178(concurrent.baseBox.value) }
    if let recording = executor as? RecordingToolExecutor { return actualBuiltin3178(recording.base) }
    for child in Mirror(reflecting: executor).children where child.label == "base" {
        if let base = child.value as? any ToolExecutor, let builtin = actualBuiltin3178(base) { return builtin }
    }
    return nil
}

@Suite("D-POLICY-09 Settings normal snapshot and actual lower refusal", .serialized)
@MainActor
struct Policy09LowerTransport3178Tests {
    @MainActor
    private struct Fixture {
        let profile: RuntimeIsolationProfile
        let center: SettingsCenter
        let bridge: BridgeStore
        let allowed: URL
        let outside: URL
        let approval: Policy09DenyApproval3178
        func cleanup() {
            bridge.chat.stopStreaming()
            if let suite = profile.userDefaultsSuiteName {
                profile.makeUserDefaults().removePersistentDomain(forName: suite)
            }
            try? profile.cleanupDisposableRoots()
        }
    }

    // Original Policy2457/3113 process boundary: owns SettingsCenter.active
    // while using the same real framework and formal synthetic test root.
    private func runWithOwnedSettingsProcess(_ testName: String) throws {
        let paths = try FormalTestIsolationPaths.resolveCurrentProcess()
        let formal = try #require(paths)
        let inherited = CommandLine.arguments
        let childArguments: [String]
        if let flag = inherited.firstIndex(of: "--test-bundle-path") {
            try #require(flag + 1 < inherited.count)
            let bundle = inherited[flag + 1]
            try #require(inherited[0].hasSuffix("/usr/libexec/swift/pm/swiftpm-testing-helper"))
            try #require(bundle.hasSuffix("/MinisCanvasAppPackageTests.xctest/Contents/MacOS/MinisCanvasAppPackageTests"))
            childArguments = ["--test-bundle-path", bundle, "--testing-library", "swift-testing", "--filter", testName]
        } else {
            // resolveCurrentProcess above validates the standalone host and its complete formal root.
            let host = formal.rootDirectory.deletingLastPathComponent()
                .appendingPathComponent("R13OriginalAppMain.app/Contents/MacOS/MinisCanvasOriginalAppMain")
            try #require(formal.packageName == "MinisCanvasApp" && inherited[0] == host.path)
            try #require(FileManager.default.isExecutableFile(atPath: host.path))
            childArguments = ["--testing-library", "swift-testing", "--no-parallel", "--filter", testName]
        }
        let evidence = formal.rootDirectory.appendingPathComponent("policy3178-child-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let rawURL = evidence.appendingPathComponent("child.raw.log")
        try #require(FileManager.default.createFile(atPath: rawURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: rawURL)
        defer { try? handle.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: inherited[0])
        child.arguments = childArguments
        var environment = ProcessInfo.processInfo.environment
        environment["POLICY3178_SETTINGS_CHILD_PARENT_PID"] = String(getpid())
        child.environment = environment
        child.standardOutput = handle
        child.standardError = handle
        let done = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in done.signal() }
        try child.run()
        print("POLICY3178_OWNED_CHILD_STARTED suite=Policy09LowerTransport3178Tests parentPID=\(getpid()) pid=\(child.processIdentifier)")
        let timedOut = done.wait(timeout: .now() + 60) != .success
        if timedOut {
            child.terminate()
            if done.wait(timeout: .now() + 2) != .success { kill(child.processIdentifier, SIGKILL) }
        }
        child.waitUntilExit()
        print("POLICY3178_OWNED_CHILD_TERMINATED suite=Policy09LowerTransport3178Tests parentPID=\(getpid()) pid=\(child.processIdentifier) reason=\(child.terminationReason.rawValue) status=\(child.terminationStatus)")
        try handle.synchronize()
        let raw = try String(contentsOf: rawURL, encoding: .utf8)
        print("POLICY3178_CHILD_RAW path=\(rawURL.path) sha256=\(DeletionGate.fingerprint(Data(raw.utf8))) exit=\(child.terminationStatus)")
        try #require(!timedOut && child.terminationStatus == 0)
        try #require(raw.contains("Test \(testName)() passed after"))
        try #require(raw.contains("Test run with 1 test in 1 suite passed after"))
    }

    private func makeFixture(ceiling: AutonomyLevel = .l3) async throws -> Fixture {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "Policy09App3178",
            processEnvironment: [:], processArguments: ["/tmp/MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled)
        let defaults = profile.makeUserDefaults()
        let approval = Policy09DenyApproval3178()
        let store = SettingsStore(directory: profile.settingsDirectory)
        store.update(\.agent.maxLoopIterations, to: 10)
        store.update(\.agent.approvalPolicy, to: .autoApprove)
        store.update(\.agent.policyRuntimeDefaults, to: ProductionPolicyDefaults(
            budget: 100, deadlineHorizon: 600, autonomyLevel: .l3, networkDomains: ["allowed.example.com"]))
        store.update(\.agent.fallbackEnabled, to: false)
        store.update(\.agent.memoryEnabled, to: false)
        store.update(\.agent.personaEnabled, to: false)
        let keychain = profile.makeKeychainStore()
        let log = profile.makeLogManager()
        let center = SettingsCenter(settingsStore: store,
            envStore: EnvVarStore(directory: profile.providerConfigurationDirectory, keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            sessionStore: SessionStore(directory: profile.sessionDirectory), logManager: log,
            mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
            skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: profile.providerConfigurationDirectory))
        if ceiling != .l3 {
            try #require(center.updatePolicyRuntimeDefaults(ProductionPolicyDefaults(
                budget: 100, deadlineHorizon: 600, autonomyLevel: ceiling, networkDomains: ["allowed.example.com"])))
        }
        #expect(center.setHistoryTurnLimit(1))
        let bridge = BridgeStore(shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults, logManager: log,
            workflowStore: WorkflowStore(storeDirectory: profile.rootDirectory.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            canvasRuntimeState: .disabled, contextManifestStore: ContextManifestStore(),
            memoryStore: center.memoryStore, providerReadinessStore: center.providerReadinessStore,
            taskCenterBindingPersistenceURL: profile.rootDirectory.appendingPathComponent("bindings.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
            })
        // The explicitly supplied canonical fixture store owns the empty skills root.
        let allowed = profile.rootDirectory.appendingPathComponent("allowed")
        let outside = profile.rootDirectory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        // Same original Policy599 admission: an owned scripted Provider with
        // discovery/apply evidence. No real network request is implemented.
        // Do not substitute a turn factory or remove route readiness guards.
        await bridge.attachProductionServices(agentSettings: center.settings.agent,
            fileAccessAllowedRoot: allowed, fileAccessDeniedRoots: [],
            sessionDirectory: profile.sessionDirectory, mcpManager: center.mcpManager,
            skillStore: center.skillStore, approvalDelegateOverride: approval, policyDefaults: center.policyRuntimeDefaults,
            canvasRuntimeState: .disabled, externalRunners: [:], externalNetworkAllowed: true,
            sessionReadSecretStore: center.envStore).value
        center.onComposerPolicyChanged = { [weak bridge] policy in bridge?.chat.restoreComposerPolicy(policy) }
        bridge.chat.onComposerPolicyChanged = { [weak center] selection in center?.composerPolicy = selection.settings }
        bridge.chat.restoreComposerPolicy(center.composerPolicy)
        #expect(SettingsCenter.active === center)
        let actual = try #require(bridge.chat.sessionStore)
        #expect(actual.directory.standardizedFileURL == center.sessionStore.directory.standardizedFileURL)
        #expect(bridge.chat.agentEngine is AgentLoopChatEngine)
        return Fixture(profile: profile, center: center, bridge: bridge, allowed: allowed, outside: outside, approval: approval)
    }

    @Test(arguments: [ApprovalPolicy.deny, .never])
    func projectToolPolicyUpdateMatchesProductionAttach(policy: ApprovalPolicy) async throws {
        let f = try await makeFixture()
        defer { f.cleanup() }

        func projectGate() throws -> ApprovalGate {
            try #require(f.bridge.chat.projectSessionHandler != nil)
            let engine = try #require(f.bridge.chat.agentEngine as? AgentLoopChatEngine)
            return try #require(engine.loop.approvalGate)
        }

        let toolNames = ProjectSessionToolContract.toolNames.sorted()
        let initial = try projectGate()
        for name in toolNames {
            try #require(initial.isKnownTool(name))
            try #require(initial.policy(for: name) == .autoApprove)
        }

        f.bridge.updateApprovalPolicy(policy)
        let updated = try projectGate()
        var settings = f.center.settings.agent
        settings.approvalPolicy = policy
        await f.bridge.attachProductionServices(agentSettings: settings,
            fileAccessAllowedRoot: f.allowed, fileAccessDeniedRoots: [],
            sessionDirectory: f.profile.sessionDirectory, mcpManager: f.center.mcpManager,
            skillStore: f.center.skillStore, approvalDelegateOverride: f.approval,
            policyDefaults: f.center.policyRuntimeDefaults, canvasRuntimeState: .disabled,
            externalRunners: [:], externalNetworkAllowed: false,
            sessionReadSecretStore: f.center.envStore).value
        let attached = try projectGate()

        for name in toolNames {
            try #require(attached.isKnownTool(name) && attached.policy(for: name) == .deny)
            #expect(updated.policy(for: name) == .deny, "Updated policy for \(name)")
        }
    }

    private func admit(_ provider: Policy09Provider3178, fixture: Fixture) throws {
        let now = Date()
        let lineage = ProviderReadinessLineage.derived(providerID: provider.name, modelID: provider.model.id, checkedAt: now)
        try #require(fixture.center.providerReadinessStore.upsert([
            ProviderReadinessPersistenceRecord(providerID: provider.name, modelID: provider.model.id,
                status: .passed, readinessState: .mock, checkedAt: now, evidenceID: "policy3178-owned-synthetic",
                isApplied: false, discoveryReceiptID: lineage.discoveryReceiptID, discoveredAt: lineage.discoveredAt)
        ]))
        try #require(fixture.center.providerReadinessStore.applyDiscoveredModels(providerID: provider.name,
            modelIDs: [provider.model.id], appliedAt: now.addingTimeInterval(1)).count == 1)
        try #require(fixture.bridge.chat.chatModelPickerReceipt(providerID: provider.name, modelID: provider.model.id) != nil)
        fixture.bridge.chat.streamingProviderOverride = provider
    }


    @Test func settingsModesReachActualLowerRefusalAndDurableStatus3178() async throws {
        guard let parent = ProcessInfo.processInfo.environment["POLICY3178_SETTINGS_CHILD_PARENT_PID"] else {
            try runWithOwnedSettingsProcess("settingsModesReachActualLowerRefusalAndDurableStatus3178")
            return
        }
        #expect(try #require(Int32(parent)) != getpid())
        // Literal original mode table: plan is a dry-run, auto-edit asks for
        // non-file effects, auto can execute granted non-browser-write actions.
        // A successful control proves the lower observer is actually wired.
        for mode in [ComposerTaskMode.plan, .autoEdit, .auto] {
            let f = try await makeFixture()
            defer { f.cleanup() }
            let chat = f.bridge.chat
            var setting = f.center.composerPolicy
            setting.mode = mode
            f.center.composerPolicy = setting
            #expect(SettingsStore(directory: f.profile.settingsDirectory).settings.agent.composerPolicy.mode == mode)
            #expect(chat.composerPolicySelection.mode == mode)
            // 浏览器只读动作（navigate）现在在计划/自动编辑模式下也免审批直接执行（2026-11-16，对齐 Claude Code）；
            // 所以计划模式的预演、自动编辑模式的询问改用会改页面的 click 来证明，自动档仍用 navigate 证明能执行。
            // 没有真实页面时，click 在取不到目标处就被拒绝、不会弹审批；自动编辑档改用访问未登记网站来触发询问。
            let provider = Policy09Provider3178(callID: "mode3178-\(mode.rawValue)",
                action: mode == .plan ? "click" : "navigate",
                url: mode == .autoEdit ? "https://unlisted.example.org/owned3178"
                                       : "https://allowed.example.com/owned3178")
            try admit(provider, fixture: f)
            let gate = Policy09PreparationGate3178()
            chat.turnPromptPreprocessPauseForTests = { await gate.pause() }
            defer { Task { await gate.release() } }
            let session = try #require(chat.activeSessionID)
            chat.draftText = "owned3178 mode \(mode.rawValue)"
            chat.submitComposer()
            let snapshot = try #require(chat.lastComposerSubmissionSnapshot)
            let task = try #require(chat.turnTaskForTests(sessionID: session))
            for _ in 0..<200 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(10)) }
            try #require(await gate.entered)
            #expect(provider.requests.isEmpty)
            #expect(snapshot.mode == mode && snapshot.autonomyCeiling == .l3)
            let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
            let builtin = try #require(actualBuiltin3178(engine.composedExecutor))
            let transport = Policy09LowerTransport3178()
            builtin.browser = transport // Existing concrete transport slot only.
            await gate.release()
            await task.value
            #expect(!chat.isStreaming)
            #expect(provider.requests.count == 2)
            let feedback = try #require(provider.requests.last).flatMap { $0.toAgentContentParts() }.compactMap { part -> (String, Bool)? in
                guard case .toolResult(let callID, _, let content, let error, _, _, _, _) = part,
                      callID == provider.callID else { return nil }
                return (content, error)
            }
            try #require(feedback.count == 1)
            let restored = try #require(SessionStore(directory: f.profile.sessionDirectory).loadSession(id: session.uuidString))
            #expect(restored.messages == chat.messages.map { $0.asLLMMessage() })
            let ledger = try ToolExecutionFactLedger(persistenceURL: f.profile.sessionDirectory.appendingPathComponent("tool-execution-facts-v4.json"))
            #expect(ledger.pendingReceipts.isEmpty)
            #expect(ledger.facts == engine.toolExecutionFactLedger.facts)
            if mode == .auto {
                #expect(transport.calls == ["browser"])
                #expect(!feedback[0].1 && feedback[0].0.contains("owned3178-browser-transport-result"))
                #expect(ledger.facts.count == 1)
                #expect(ledger.facts.first?.toolCallID == provider.callID)
                #expect(ledger.facts.first?.status == .succeeded)
                #expect(await f.approval.requests.isEmpty)
                #expect(!restored.messages.contains { $0.content.contains("项工具调用未执行") })
            } else {
                #expect(transport.calls.isEmpty) // Lower dispatch, not effect absence.
                #expect(feedback[0].1)
                #expect(!feedback[0].0.contains("owned3178-browser-transport-result"))
                #expect(ledger.facts.isEmpty)
                #expect(f.bridge.composerApprovalReceipts.isEmpty)
                let status = mode == .plan ? "计划模式：1 项工具调用未执行。" : "执行前拦截：1 项工具调用未执行。"
                // These fixed projections are emitted only from Core's typed
                // dryRun / blockedBeforeExecution metadata, never absent facts.
                #expect(chat.messages.contains { $0.role == .assistant && $0.content.contains(status) })
                #expect(restored.messages.contains { $0.role == .assistant && $0.content.contains(status) })
                if mode == .plan {
                    #expect(feedback[0].0.contains("dry-run"))
                    #expect(await f.approval.requests.isEmpty)
                } else {
                    #expect(feedback[0].0.contains(ComposerAuthorizationError.approvalDenied("owned3178 denied").localizedDescription))
                    let requests = await f.approval.requests
                    try #require(requests.count == 1)
                    #expect(requests[0].toolName == "browser" && requests[0].composerMode == mode.rawValue)
                    #expect(requests[0].callID == provider.callID && requests[0].taskID == snapshot.taskID)
                    #expect(requests[0].sessionID == snapshot.sessionID && requests[0].turnID == snapshot.turnID)
                    #expect(requests[0].policyRevision == snapshot.policyRevision && requests[0].grantEpoch == snapshot.grantEpoch)
                    #expect(requests[0].identityDigest != nil && requests[0].inputDigest != nil)
                }
            }
        }
    }

    private enum FrozenAdmissionChange: String, CaseIterable {
        case ordinaryControl, childControl, siblingLeaseRotation, approvalABA
        case explicitRevocation, unmarkedRotation, unmarkedEpochOnly
        case childEquivalentAttach, approvalSetting, budgetSetting, externalNetwork, safetySetting
        case addedDeniedDirectory, controlledLoopbackDisabled, equivalentBAfterApprovalChange
        case unequalBAfterApprovalChange, unequalAAfterApprovalABA
    }

    @Test func frozenDialogueAdmissionRejectsChangedAuthorityG01() async throws {
        guard let parent = ProcessInfo.processInfo.environment["POLICY3178_SETTINGS_CHILD_PARENT_PID"] else {
            try runWithOwnedSettingsProcess("frozenDialogueAdmissionRejectsChangedAuthorityG01")
            return
        }
        #expect(try #require(Int32(parent)) != getpid())
        for change in FrozenAdmissionChange.allCases {
            let f = try await makeFixture()
            defer { f.cleanup() }
            let chat = f.bridge.chat
            func reattach(externalNetworkAllowed: Bool = true,
                          controlledFieldLoopbackAllowed: Bool = false, deniedRoots: [URL] = []) async {
                await f.bridge.attachProductionServices(agentSettings: f.center.settings.agent,
                    fileAccessAllowedRoot: f.allowed, fileAccessDeniedRoots: deniedRoots,
                    sessionDirectory: f.profile.sessionDirectory, mcpManager: f.center.mcpManager,
                    skillStore: f.center.skillStore, approvalDelegateOverride: f.approval,
                    policyDefaults: f.center.policyRuntimeDefaults, canvasRuntimeState: .disabled,
                    externalRunners: [:], externalNetworkAllowed: externalNetworkAllowed,
                    controlledFieldLoopbackAllowed: controlledFieldLoopbackAllowed,
                    sessionReadSecretStore: f.center.envStore).value
            }
            let wire = change == .controlledLoopbackDisabled
                ? try ComposerWire3090(reply: "G01 owned loopback response") : nil
            defer { wire?.stop() }
            let provider = Policy09Provider3178(callID: "g01-" + change.rawValue, returnsToolCall: false)
            var controlledProvider: (any LLMProvider)?
            if let wire {
                await reattach(externalNetworkAllowed: false, controlledFieldLoopbackAllowed: true)
                try #require(!f.bridge.productionExternalNetworkAllowed && f.bridge.productionControlledFieldLoopbackAllowed)
                let record = EnvVarEntry(name: "G01_OWNED_LOOPBACK", value: "owned-synthetic-g01",
                    isSecret: true, baseURL: "http://127.0.0.1:\(wire.port)",
                    modelNames: ["gpt-4o"], protocolType: .openaiCompatible)
                chat.providerRecordsSource = { [record] }
                chat.schedulerCredentialVersionSource = { _ in "owned-g01-loopback-revision" }
                try #require(f.center.providerReadinessStore.upsert([ProviderReadinessPersistenceRecord(
                    providerID: record.name, modelID: "gpt-4o", status: .passed, readinessState: .live,
                    checkedAt: Date(), evidenceID: "live-settings:" + String(repeating: "a", count: 64),
                    isApplied: true)]))
                try #require(chat.applyChatModel(providerID: record.name, modelID: "gpt-4o"))
                let actual = try #require(try chat.activeProvider() as? OpenAICompatibleProvider)
                try #require(actual.controlledFieldLoopbackOnly)
                let route = try #require(chat.providerRuntimeRouteFactory)
                try #require(route(actual) != nil)
                controlledProvider = actual
            } else {
                try admit(provider, fixture: f)
            }
            var historicalApprovalMap: [String: ApprovalPolicy]?
            if change == .equivalentBAfterApprovalChange || change == .unequalBAfterApprovalChange
                || change == .unequalAAfterApprovalABA {
                if change == .unequalAAfterApprovalABA {
                    try #require(f.center.approvalPolicy == .autoApprove)
                    let initialEngine = try #require(chat.agentEngine as? AgentLoopChatEngine)
                    historicalApprovalMap = try #require(initialEngine.loop.approvalGate).policyByTool
                }
                f.center.onApprovalPolicyChanged = { [weak bridge = f.bridge] policy in bridge?.updateApprovalPolicy(policy) }
                let revisionA = chat.composerPolicyFacts.revision
                f.center.approvalPolicy = .alwaysAsk
                try #require(f.center.approvalPolicy == .alwaysAsk)
                try #require(chat.composerPolicyFacts.revision != revisionA)
                if change == .unequalAAfterApprovalABA {
                    let revisionB = chat.composerPolicyFacts.revision
                    f.center.approvalPolicy = .autoApprove
                    try #require(f.center.approvalPolicy == .autoApprove)
                    try #require(chat.composerPolicyFacts.revision != revisionA)
                    try #require(chat.composerPolicyFacts.revision != revisionB)
                }
                if change == .equivalentBAfterApprovalChange {
                    // Publish the fully assembled B authority before freezing
                    // the positive turn. The other arm keeps the updater's
                    // gate and exercises its real mismatch with full attach.
                    await reattach()
                }
            }
            let gate = Policy09PreparationGate3178()
            chat.turnPromptPreprocessPauseForTests = { await gate.pause() }
            defer { Task { await gate.release() } }
            let session = try #require(chat.activeSessionID)
            chat.draftText = "Owned G01 admission " + change.rawValue
            let childID = "owned-g01-child"
            if change == .childControl || change == .childEquivalentAttach {
                // Use the same inherited task-local Core uses when the
                // already-wrapped production transport serves a child.
                UsageTelemetryContext.$childOrigin.withValue(ChildUsageOrigin(taskID: childID)) {
                    chat.submitComposer()
                }
            } else {
                chat.submitComposer()
            }
            for _ in 0..<200 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(10)) }
            try #require(await gate.entered)
            let snapshot = try #require(chat.lastComposerSubmissionSnapshot)
            let task = try #require(chat.turnTaskForTests(sessionID: session))
            let identity = try #require(chat.activeExecutionIdentity(for: session))
            let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
            let lifecycle = try #require(engine.contextWritebackGate.lifecycleStore)
            try #require(provider.requests.isEmpty)
            try #require(wire?.requests.isEmpty != false)
            try #require(chat.terminalReceipt(for: identity) == nil)
            try #require(lifecycle.record(for: identity) == nil)
            let original = chat.composerPolicyFacts
            try #require(original.revision == snapshot.policyRevision && original.grantEpoch == snapshot.grantEpoch)

            func publish(revision: String, epoch: String, revoked: Bool) {
                chat.configureComposerPolicy(ComposerPolicyFactSource(
                    knownCapabilities: original.knownCapabilities, grantedCapabilities: original.grantedCapabilities,
                    capabilityGrantBindings: original.capabilityGrantBindings,
                    allowedWriteRoots: original.allowedWriteRoots, workspaceID: original.workspaceID,
                    revision: revision, grantEpoch: epoch, leaseID: original.leaseID,
                    expiresAt: original.expiresAt, revoked: revoked, autonomyCeiling: original.autonomyCeiling))
            }
            switch change {
            case .ordinaryControl, .childControl:
                break
            case .siblingLeaseRotation:
                let prepare = try #require(chat.prepareTopLevelTaskPolicy)
                try #require(prepare("g01-sibling-" + UUID().uuidString, Date(), nil, false))
                let sibling = chat.composerPolicyFacts
                try #require(sibling.revision == original.revision)
                try #require(sibling.grantEpoch != original.grantEpoch)
                try #require(sibling.leaseID != original.leaseID)
                try #require(!sibling.revoked)
            case .approvalABA, .approvalSetting:
                f.center.onApprovalPolicyChanged = { [weak bridge = f.bridge] policy in bridge?.updateApprovalPolicy(policy) }
                f.center.approvalPolicy = .deny
                try #require(f.center.approvalPolicy == .deny)
                let deniedRevision = chat.composerPolicyFacts.revision
                try #require(deniedRevision != original.revision)
                if change == .approvalABA {
                    f.center.approvalPolicy = .autoApprove
                    try #require(f.center.approvalPolicy == .autoApprove)
                    try #require(chat.composerPolicyFacts.revision != deniedRevision)
                    // The old facts' semantic fields are equal again after A→B→A.
                    try #require(chat.composerPolicyFacts.grantedCapabilities == original.grantedCapabilities)
                    try #require(chat.composerPolicyFacts.allowedWriteRoots == original.allowedWriteRoots)
                }
            case .explicitRevocation:
                publish(revision: original.revision, epoch: original.grantEpoch + "-revoked", revoked: true)
                try #require(chat.composerPolicyFacts.revoked)
                try #require(chat.composerPolicyFacts.revision == original.revision)
                try #require(chat.composerPolicyFacts.leaseID == original.leaseID)
                try #require(chat.composerPolicyFacts.grantEpoch != original.grantEpoch)
            case .unmarkedRotation:
                publish(revision: original.revision + "-rotated", epoch: original.grantEpoch + "-rotated", revoked: false)
                try #require(chat.composerPolicyFacts.revision != original.revision)
                try #require(chat.composerPolicyFacts.grantEpoch != original.grantEpoch)
            case .unmarkedEpochOnly:
                publish(revision: original.revision, epoch: original.grantEpoch + "-epoch-only", revoked: false)
                try #require(chat.composerPolicyFacts.revision == original.revision)
                try #require(chat.composerPolicyFacts.leaseID == original.leaseID)
                try #require(chat.composerPolicyFacts.grantEpoch != original.grantEpoch)
            case .childEquivalentAttach:
                let selection = chat.composerPolicySelection
                try #require(chat.retainsInheritedChildAuthority(original, selection: selection))
                await reattach()
                let rebound = chat.composerPolicyFacts
                try #require(rebound.revision != original.revision)
                try #require(rebound.knownCapabilities == original.knownCapabilities)
                try #require(rebound.grantedCapabilities == original.grantedCapabilities)
                try #require(rebound.capabilityGrantBindings == original.capabilityGrantBindings)
                try #require(rebound.allowedWriteRoots == original.allowedWriteRoots)
                try #require(rebound.autonomyCeiling == original.autonomyCeiling)
                try #require(!chat.retainsInheritedChildAuthority(original, selection: selection))
            case .budgetSetting:
                var defaults = f.center.policyRuntimeDefaults
                defaults.budget -= 1
                try #require(f.center.updatePolicyRuntimeDefaults(defaults))
                try #require(f.center.policyRuntimeDefaults == defaults)
                await reattach()
                try #require(chat.composerPolicyFacts.revision != original.revision)
            case .externalNetwork:
                await reattach(externalNetworkAllowed: false)
                try #require(!f.bridge.productionExternalNetworkAllowed)
                try #require(chat.composerPolicyFacts.revision != original.revision)
            case .safetySetting:
                f.center.safeModeEnabled = true
                try #require(f.center.safetyRuntimeSnapshot.safeModeEnabled)
                _ = f.bridge.updateSafetyRuntimeSnapshot(f.center.safetyRuntimeSnapshot)
                await reattach()
                try #require(chat.composerPolicyFacts.revision != original.revision)
            case .addedDeniedDirectory:
                let directory = f.allowed.appendingPathComponent("newly-denied", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let before = try #require(f.bridge.productionBuiltinToolExecutor)
                try #require(before.explicitDeniedRoots.isEmpty)
                try #require(f.center.addFileAccessDeniedRoot(directory.path))
                let denied = f.center.fileAccessDeniedRoots.map { URL(fileURLWithPath: $0, isDirectory: true) }
                await reattach(deniedRoots: denied)
                let after = try #require(f.bridge.productionBuiltinToolExecutor)
                try #require(after.deniedRoots.contains {
                    $0.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path
                })
                try #require(after.allowedRoot == before.allowedRoot)
                try #require(chat.composerPolicyFacts.allowedWriteRoots == original.allowedWriteRoots)
                try #require(chat.composerPolicyFacts.revision != original.revision)
            case .controlledLoopbackDisabled:
                await reattach(externalNetworkAllowed: false)
                try #require(!f.bridge.productionExternalNetworkAllowed && !f.bridge.productionControlledFieldLoopbackAllowed)
                let actual = try #require(controlledProvider)
                let route = try #require(chat.providerRuntimeRouteFactory)
                try #require(route(actual) == nil)
                try #require(chat.composerPolicyFacts.revision != original.revision)
            case .equivalentBAfterApprovalChange, .unequalBAfterApprovalChange, .unequalAAfterApprovalABA:
                let before = try #require(engine.loop.approvalGate)
                let beforeOwner = try #require(f.bridge.productionBuiltinToolExecutor)
                let beforeDefaults = f.center.policyRuntimeDefaults
                let beforeSafetyGeneration = f.bridge.safetyRuntimeGeneration
                let beforeSafety = f.bridge.safetyRuntimeSnapshot
                let beforeNetwork = f.bridge.productionExternalNetworkAllowed
                let beforeLoopback = f.bridge.productionControlledFieldLoopbackAllowed
                let projectTools = ["project_list", "project_resolve", "session_create"]
                try #require(Set(projectTools) == ProjectSessionToolContract.toolNames)
                let expectedPolicy: ApprovalPolicy = change == .unequalAAfterApprovalABA ? .autoApprove : .alwaysAsk
                try #require(f.center.approvalPolicy == expectedPolicy && f.center.settings.agent.approvalPolicy == expectedPolicy)
                await reattach()
                let reboundEngine = try #require(chat.agentEngine as? AgentLoopChatEngine)
                try #require(reboundEngine.contextWritebackGate.lifecycleStore === lifecycle)
                let after = try #require(reboundEngine.loop.approvalGate)
                let afterOwner = try #require(f.bridge.productionBuiltinToolExecutor)
                let rebound = chat.composerPolicyFacts
                try #require(f.center.approvalPolicy == expectedPolicy && f.center.settings.agent.approvalPolicy == expectedPolicy)
                try #require(rebound.revision != original.revision)
                try #require(!original.revoked && !rebound.revoked && rebound.workspaceID == original.workspaceID)
                try #require(rebound.knownCapabilities == original.knownCapabilities)
                try #require(rebound.grantedCapabilities == original.grantedCapabilities)
                try #require(rebound.capabilityGrantBindings == original.capabilityGrantBindings)
                try #require(rebound.allowedWriteRoots == original.allowedWriteRoots)
                try #require(rebound.autonomyCeiling == original.autonomyCeiling)
                try #require(f.center.policyRuntimeDefaults == beforeDefaults)
                try #require(f.bridge.safetyRuntimeGeneration == beforeSafetyGeneration)
                try #require(f.bridge.safetyRuntimeSnapshot == beforeSafety)
                try #require(f.bridge.productionExternalNetworkAllowed == beforeNetwork)
                try #require(f.bridge.productionControlledFieldLoopbackAllowed == beforeLoopback)
                try #require(afterOwner.allowedRoot == beforeOwner.allowedRoot)
                try #require(afterOwner.additionalAllowedRoots == beforeOwner.additionalAllowedRoots)
                try #require(afterOwner.deniedRoots == beforeOwner.deniedRoots)
                try #require(afterOwner.explicitDeniedRoots == beforeOwner.explicitDeniedRoots)
                try #require(afterOwner.appPrivateDeniedRoots == beforeOwner.appPrivateDeniedRoots)
                try #require(after.terminalPolicySnapshot == before.terminalPolicySnapshot)
                let global = ApprovalGate.policyOverrides(for: expectedPolicy)
                for (tool, policy) in global {
                    try #require(before.policyByTool[tool] == policy && after.policyByTool[tool] == policy)
                }
                for tool in projectTools {
                    try #require(after.policyByTool[tool] == expectedPolicy && after.isKnownTool(tool))
                    try #require(before.policyByTool[tool] == expectedPolicy && before.isKnownTool(tool))
                }
                // A live update and a reattachment with the same saved policy
                // assemble the same tool table, while rotating authority.
                try #require(before.policyByTool == after.policyByTool)
                if change == .unequalAAfterApprovalABA {
                    let historical = try #require(historicalApprovalMap)
                    try #require(after.policyByTool == historical)
                }
            }

            await gate.release()
            await task.value
            let reachedProvider = wire.map { !$0.requests.isEmpty } ?? !provider.requests.isEmpty
            #expect(wire?.captureFailure == nil)
            let status = lifecycle.record(for: identity)?.status
            let terminal = chat.terminalReceipt(for: identity)?.outcome
            let evidence = Comment(rawValue: change.rawValue)
            print("G01_ADMISSION case=\(change.rawValue) providerReached=\(reachedProvider)"
                + " lifecycle=\(status?.rawValue ?? "none") terminal=\(terminal?.rawValue ?? "none")")
            #expect(!chat.isStreaming, evidence)
            switch change {
            case .ordinaryControl, .childControl, .siblingLeaseRotation, .equivalentBAfterApprovalChange:
                #expect(reachedProvider, evidence)
                #expect(status == .completed, evidence)
                #expect(terminal == .succeeded, evidence)
                if change == .childControl { #expect(provider.childTaskIDs.contains(childID)) }
            case .safetySetting:
                // A safety lock may terminate preparation before the engine
                // owns a lifecycle record. Do not count it as a guard witness.
                #expect(!reachedProvider, evidence)
                #expect(terminal == .cancelled, evidence)
            case .unmarkedEpochOnly:
                // An unmarked publisher cannot present a same-lease epoch
                // change as the actual sibling issuance exercised above.
                #expect(!reachedProvider && status == .cancelled && terminal == .cancelled, evidence)
            default:
                #expect(!reachedProvider, evidence)
                #expect(status == .cancelled, evidence)
                #expect(terminal == .cancelled, evidence)
            }
        }
    }

    @Test func loweredSettingsCeilingRejectsNormalModeBeforeProvider3178() async throws {
        guard let parent = ProcessInfo.processInfo.environment["POLICY3178_SETTINGS_CHILD_PARENT_PID"] else {
            try runWithOwnedSettingsProcess("loweredSettingsCeilingRejectsNormalModeBeforeProvider3178")
            return
        }
        #expect(try #require(Int32(parent)) != getpid())
        // Lower through the real settings setter before initial composition;
        // the older committedUserCeiling test separately covers live rebind.
        let f = try await makeFixture(ceiling: .l1)
        defer { f.cleanup() }
        let lowered = ProductionPolicyDefaults(budget: 100, deadlineHorizon: 600, autonomyLevel: .l1,
                                               networkDomains: ["allowed.example.com"])
        #expect(SettingsStore(directory: f.profile.settingsDirectory).settings.agent.policyRuntimeDefaults == lowered)
        var setting = f.center.composerPolicy
        setting.mode = .autoEdit
        f.center.composerPolicy = setting
        let chat = f.bridge.chat
        let provider = Policy09Provider3178(callID: "ceiling3178")
        try admit(provider, fixture: f)
        let gate = Policy09PreparationGate3178()
        chat.turnPromptPreprocessPauseForTests = { await gate.pause() }
        defer { Task { await gate.release() } }
        let session = try #require(chat.activeSessionID)
        chat.draftText = "owned3178 above user L1 ceiling"
        chat.submitComposer()
        let snapshot = try #require(chat.lastComposerSubmissionSnapshot)
        let task = try #require(chat.turnTaskForTests(sessionID: session))
        for _ in 0..<200 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(10)) }
        try #require(await gate.entered)
        let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        let builtin = try #require(actualBuiltin3178(engine.composedExecutor))
        let transport = Policy09LowerTransport3178()
        builtin.browser = transport
        #expect(snapshot.mode == .autoEdit && snapshot.autonomyCeiling == .l1)
        #expect(chat.composerPolicyFacts.autonomyCeiling == .l1)
        await gate.release()
        await task.value
        #expect(provider.requests.isEmpty && transport.calls.isEmpty)
        #expect(await f.approval.requests.isEmpty)
        #expect(engine.toolExecutionFactLedger.facts.isEmpty && engine.toolExecutionFactLedger.pendingReceipts.isEmpty)
        let error = ComposerAuthorizationError.modeExceedsAutonomyCeiling(required: .l2, maximum: .l1)
        #expect(chat.messages.contains { $0.role == .assistant && $0.content.contains(error.localizedDescription) })
        let restored = try #require(SessionStore(directory: f.profile.sessionDirectory).loadSession(id: session.uuidString))
        #expect(restored.messages == chat.messages.map { $0.asLLMMessage() })
        // No call existed here: do not manufacture a denied tool receipt.
        #expect(!restored.messages.contains { $0.content.contains("项工具调用未执行") })
    }
}
