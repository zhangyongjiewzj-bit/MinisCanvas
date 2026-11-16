import Darwin
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

private actor Policy08PreparationGate3155 {
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

/// Only supplies model replies and records the real wire arguments. It never
/// chooses a budget, wraps an executor, creates a receipt, or terminates a loop.
private final class Policy08AppProvider3155: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    struct Call: Sendable {
        let messages: [LLMMessage]
        let systemPrompt: String
        let maxTokens: Int
        let tools: [String]
    }
    private let lock = NSLock()
    private var currentModel: LLMModel
    private var material: String? = "owned-policy3155-script"
    private var captured: [Call] = []
    private var streamEntries = 0
    let directory: URL
    let callPrefix: String
    let responseText: String
    let name = "policy3155-local"
    let capabilities: Set<ProviderCapability> = [.tools]
    var model: LLMModel {
        get { lock.withLock { currentModel } }
        set { lock.withLock { currentModel = newValue } }
    }
    var runtimeConfigurationMaterial: String? {
        get { lock.withLock { material } }
        set { lock.withLock { material = newValue } }
    }
    var calls: [Call] { lock.withLock { captured } }
    var streamingCalls: Int { lock.withLock { streamEntries } }
    init(directory: URL, prefix: String, clipped: Bool, growingContext: Bool = false) {
        self.directory = directory
        callPrefix = prefix
        responseText = growingContext ? String(repeating: "owned progress ", count: 150) : "read owned sample"
        // Each turn performs a fresh discovery/apply. A refresh must not undo
        // the prior model's already-applied authority just to return a new receipt.
        let modelID = (clipped ? "policy3155-clipped" : "policy3155-unclipped") + ":" + prefix
        currentModel = LLMModel(id: modelID,
            displayName: "Owned local budget observer", provider: name,
            contextWindow: 32_768, maxOutputTokens: clipped ? 3_000 : 16_384)
    }
    private func reply(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                       maxTokens: Int) throws -> LLMResponse {
        let index = lock.withLock {
            captured.append(Call(messages: messages, systemPrompt: systemPrompt ?? "",
                maxTokens: maxTokens, tools: tools.map(\.name)))
            return captured.count
        }
        // Different owned paths avoid a repeated-input loop detector without
        // mutating that production detector or the iteration limit.
        let arguments: [String: Any] = ["tool_title": "Read owned budget sample",
            "path": directory.appendingPathComponent("sample-\(index).txt").path]
        let raw = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return LLMResponse(text: responseText, stopReason: "tool_calls", usage: nil,
            toolCalls: [LLMToolCall(id: "\(callPrefix)-\(index)", name: "file_read",
                rawArguments: String(decoding: raw, as: UTF8.self), arguments: arguments)])
    }
    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try reply(messages: messages, systemPrompt: systemPrompt, tools: [], maxTokens: maxTokens)
    }
    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?,
        tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try reply(messages: messages, systemPrompt: systemPrompt, tools: tools, maxTokens: maxTokens)
    }
    nonisolated(nonsending) func streamMessage(messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        lock.withLock { streamEntries += 1 }
        throw CancellationError() // No streaming capability is advertised.
    }
}

@Suite("D-POLICY-08 actual App request budgets and unchanged permissions", .serialized)
@MainActor
struct Policy08ActualAppBudget3155Tests {
    @MainActor
    private struct Fixture {
        let profile: RuntimeIsolationProfile
        let center: SettingsCenter
        let bridge: BridgeStore
        let allowed: URL
        let outside: URL
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
        let evidence = formal.rootDirectory.appendingPathComponent("policy3155-child-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let rawURL = evidence.appendingPathComponent("child.raw.log")
        try #require(FileManager.default.createFile(atPath: rawURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: rawURL)
        defer { try? handle.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: inherited[0])
        child.arguments = childArguments
        var environment = ProcessInfo.processInfo.environment
        environment["POLICY3155_SETTINGS_CHILD_PARENT_PID"] = String(getpid())
        child.environment = environment
        child.standardOutput = handle
        child.standardError = handle
        let done = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in done.signal() }
        try child.run()
        print("POLICY3155_OWNED_CHILD_STARTED suite=Policy08ActualAppBudget3155Tests parentPID=\(getpid()) pid=\(child.processIdentifier)")
        let timedOut = done.wait(timeout: .now() + 180) != .success
        if timedOut {
            child.terminate()
            if done.wait(timeout: .now() + 2) != .success { kill(child.processIdentifier, SIGKILL) }
        }
        child.waitUntilExit()
        print("POLICY3155_OWNED_CHILD_TERMINATED suite=Policy08ActualAppBudget3155Tests parentPID=\(getpid()) pid=\(child.processIdentifier) reason=\(child.terminationReason.rawValue) status=\(child.terminationStatus)")
        try handle.synchronize()
        let raw = try String(contentsOf: rawURL, encoding: .utf8)
        print("POLICY3155_CHILD_RAW path=\(rawURL.path) sha256=\(DeletionGate.fingerprint(Data(raw.utf8))) exit=\(child.terminationStatus)")
        try #require(!timedOut && child.terminationStatus == 0)
        try #require(raw.contains("Test \(testName)() passed after"))
        try #require(raw.contains("Test run with 1 test in 1 suite passed after"))
    }

    private func makeFixture(contextLength: Int?) async throws -> Fixture {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "Policy08App3155",
            processEnvironment: [:], processArguments: ["/tmp/MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled)
        let defaults = profile.makeUserDefaults()
        let store = SettingsStore(directory: profile.settingsDirectory)
        store.update(\.agent.maxLoopIterations, to: 10)
        store.update(\.agent.approvalPolicy, to: .autoApprove)
        store.update(\.agent.policyRuntimeDefaults, to: ProductionPolicyDefaults(
            budget: 100, deadlineHorizon: 600, autonomyLevel: .l3, networkDomains: []))
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
        if let contextLength { #expect(center.setContextLengthTokens(contextLength)) }
        else { #expect(center.contextLengthTokens == 0) }
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
        let allowed = profile.rootDirectory.appendingPathComponent("allowed").standardizedFileURL
        let outside = profile.rootDirectory.appendingPathComponent("outside").standardizedFileURL
        for directory in [allowed, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for index in 1...15 {
                try (directory == allowed ? "owned-budget-sample" : "outside-must-not-be-read")
                    .write(to: directory.appendingPathComponent("sample-\(index).txt"), atomically: true, encoding: .utf8)
            }
        }
        // Same original Policy599 admission: an owned scripted Provider with
        // discovery/apply evidence. No real network request is implemented.
        // Do not substitute a turn factory or remove route readiness guards.
        await bridge.attachProductionServices(agentSettings: center.settings.agent,
            fileAccessAllowedRoot: allowed, fileAccessDeniedRoots: [],
            sessionDirectory: profile.sessionDirectory, mcpManager: center.mcpManager,
            skillStore: center.skillStore, policyDefaults: center.policyRuntimeDefaults,
            canvasRuntimeState: .disabled, externalRunners: [:], externalNetworkAllowed: true,
            sessionReadSecretStore: center.envStore).value
        center.onComposerPolicyChanged = { [weak bridge] policy in bridge?.chat.restoreComposerPolicy(policy) }
        bridge.chat.onComposerPolicyChanged = { [weak center] selection in center?.composerPolicy = selection.settings }
        bridge.chat.restoreComposerPolicy(center.composerPolicy)
        #expect(SettingsCenter.active === center)
        let actual = try #require(bridge.chat.sessionStore)
        #expect(actual.directory.standardizedFileURL == center.sessionStore.directory.standardizedFileURL)
        #expect(bridge.chat.agentEngine is AgentLoopChatEngine)
        return Fixture(profile: profile, center: center, bridge: bridge, allowed: allowed, outside: outside)
    }

    private func admit(_ provider: Policy08AppProvider3155, fixture: Fixture) throws {
        let now = Date()
        let lineage = ProviderReadinessLineage.derived(providerID: provider.name, modelID: provider.model.id, checkedAt: now)
        try #require(fixture.center.providerReadinessStore.upsert([
            ProviderReadinessPersistenceRecord(providerID: provider.name, modelID: provider.model.id,
                status: .passed, readinessState: .mock, checkedAt: now, evidenceID: "policy3155-owned-synthetic",
                isApplied: false, discoveryReceiptID: lineage.discoveryReceiptID, discoveredAt: lineage.discoveredAt)
        ]))
        try #require(fixture.center.providerReadinessStore.applyDiscoveredModels(providerID: provider.name,
            modelIDs: [provider.model.id], appliedAt: now.addingTimeInterval(1)).count == 1)
        try #require(fixture.bridge.chat.chatModelPickerReceipt(providerID: provider.name, modelID: provider.model.id) != nil)
        fixture.bridge.chat.streamingProviderOverride = provider
    }

    @Test func threeEffortsReachActualAppBudgetsAndReceipts3155() async throws {
        guard let parent = ProcessInfo.processInfo.environment["POLICY3155_SETTINGS_CHILD_PARENT_PID"] else {
            try runWithOwnedSettingsProcess("threeEffortsReachActualAppBudgetsAndReceipts3155")
            return
        }
        #expect(try #require(Int32(parent)) != getpid())
        for clipped in [false, true] {
            for scenario in ["allowed", "noGrant", "outside"] {
                let f = try await makeFixture(contextLength: clipped ? 16_384 : nil)
                defer { f.cleanup() }
                let chat = f.bridge.chat
                if scenario == "noGrant" {
                    let original = chat.composerPolicyFacts
                    chat.configureComposerPolicy(ComposerPolicyFactSource(
                        knownCapabilities: original.knownCapabilities,
                        grantedCapabilities: original.grantedCapabilities.subtracting(["file_read"]),
                        capabilityGrantBindings: original.capabilityGrantBindings,
                        allowedWriteRoots: original.allowedWriteRoots, workspaceID: original.workspaceID,
                        revision: original.revision, grantEpoch: original.grantEpoch, leaseID: original.leaseID,
                        expiresAt: original.expiresAt, autonomyCeiling: original.autonomyCeiling))
                }
                let permission = chat.composerPolicyFacts
                let session = try #require(chat.activeSessionID)
                var snapshots: [ComposerSubmissionSnapshot] = []
                let cases: [(ComposerEffort, ComposerEffort, Int, Int)] = clipped
                    ? [(.low, .high, 5, 1_125), (.standard, .low, 10, 2_250), (.high, .standard, 15, 3_000)]
                    : [(.low, .high, 5, 6_144), (.standard, .low, 10, 12_288), (.high, .standard, 15, 16_384)]
                for (effort, next, iterations, tokens) in cases {
                    let prefix = "app3155-\(clipped)-\(scenario)-\(effort.rawValue)"
                    let provider = Policy08AppProvider3155(directory: scenario == "outside" ? f.outside : f.allowed,
                        prefix: prefix, clipped: clipped)
                    try admit(provider, fixture: f)
                    var selection = f.center.composerPolicy
                    selection.mode = .auto
                    selection.approvalScope = .request
                    selection.effort = effort
                    f.center.composerPolicy = selection
                    #expect(chat.composerPolicySelection.effort == effort)
                    let gate = Policy08PreparationGate3155()
                    chat.turnPromptPreprocessPauseForTests = { await gate.pause() }
                    defer { Task { await gate.release() } }
                    chat.draftText = prefix
                    chat.submitComposer()
                    let snapshot = try #require(chat.lastComposerSubmissionSnapshot)
                    let identity = try #require(chat.activeExecutionIdentity(for: session))
                    let task = try #require(chat.turnTaskForTests(sessionID: session))
                    let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
                    for _ in 0..<200 {
                        if await gate.entered { break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    let entered = await gate.entered
                    try #require(entered)
                    #expect(provider.calls.isEmpty)
                    #expect(snapshot.effort == effort && snapshot.mode == .auto)
                    #expect(snapshot.sessionID == session.uuidString)
                    #expect(chat.composerPolicyFacts.knownCapabilities == permission.knownCapabilities)
                    #expect(chat.composerPolicyFacts.grantedCapabilities == permission.grantedCapabilities)
                    #expect(chat.composerPolicyFacts.allowedWriteRoots == permission.allowedWriteRoots)
                    #expect(chat.composerPolicyFacts.autonomyCeiling == permission.autonomyCeiling)
                    selection.effort = next
                    f.center.composerPolicy = selection
                    #expect(chat.lastComposerSubmissionSnapshot == snapshot)
                    await gate.release()
                    if scenario == "outside" {
                        // 5ae68c4: outside reads require a fresh bound decision,
                        // even under autoApprove. Reject through the real center.
                        for index in 1...iterations {
                            for _ in 0..<500 where f.bridge.approvalCenter.pendingRequest == nil && chat.isStreaming {
                                try await Task.sleep(for: .milliseconds(10))
                            }
                            let request = try #require(f.bridge.approvalCenter.pendingRequest)
                            let path = f.outside.appendingPathComponent("sample-\(index).txt").path
                            let input = ComposerToolInput(values: [
                                "tool_title": .string("Read owned budget sample"), "path": .string(path)])
                            try #require(request.toolName == "file_read")
                            try #require(request.callID == "\(prefix)-\(index)")
                            try #require(request.sessionID == session.uuidString)
                            try #require(request.inputDigest == input.digest)
                            try #require(request.identityDigest?.count == 64)
                            try #require(request.turnID == snapshot.turnID && request.taskID == snapshot.taskID
                                && request.attemptID == snapshot.attemptID && request.messageID == snapshot.messageID
                                && request.policyRevision == snapshot.policyRevision && request.grantEpoch == snapshot.grantEpoch)
                            try #require(request.persistentAllowOffer == nil)
                            #expect(engine.toolExecutionFactLedger.facts.filter { $0.executionIdentity == identity }.isEmpty)
                            f.bridge.approvalCenter.resolve(approved: false, reason: "POLICY3155_OUTSIDE_READ_DENIED",
                                confirmed: false, requestID: request.id)
                        }
                    }
                    await task.value // Await the actual owned run, including its error terminal.
                    #expect(f.bridge.approvalCenter.pendingRequest == nil)
                    #expect(!chat.isStreaming)
                    #expect(chat.lastComposerSubmissionSnapshot == snapshot)
                    #expect(chat.terminalReceipt(for: identity)?.outcome == .failed)
                    let assistant = try #require(chat.messages.last(where: { $0.role == .assistant }))
                    #expect(assistant.content.contains(AgentLoopError.maxIterationsExceeded(iterations).localizedDescription))
                    let calls = provider.calls
                    #expect(calls.count == iterations)
                    #expect(calls.map(\.maxTokens) == Array(repeating: tokens, count: iterations))
                    #expect(calls.allSatisfy { $0.tools.contains("file_read") })
                    #expect(provider.streamingCalls == 0)
                    for (index, call) in calls.enumerated() {
                        let feedback = call.messages.filter { $0.role == .tool }
                        #expect(feedback.count == index)
                        #expect(feedback.map(\.toolCallID) == (1...max(1, index)).prefix(index).map { "\(prefix)-\($0)" })
                        if scenario == "allowed" {
                            #expect(feedback.allSatisfy { $0.content.contains("owned-budget-sample") })
                        } else {
                            for result in feedback {
                                let refusal = scenario == "noGrant"
                                    ? ComposerAuthorizationError.missingCapabilityGrant("file_read")
                                    : ComposerAuthorizationError.approvalDenied("POLICY3155_OUTSIDE_READ_DENIED")
                                #expect(result.content.contains(refusal.localizedDescription))
                            }
                            #expect(!call.messages.contains { $0.content.contains("outside-must-not-be-read") })
                            #expect(!call.messages.contains { $0.content.contains("owned-budget-sample") })
                        }
                        if clipped {
                            let inputCost = try #require(AgentLoopChatEngine.estimatedContextCost(
                                call.messages, systemPrompt: call.systemPrompt))
                            #expect(inputCost + call.maxTokens <= 16_384)
                            let modelCeiling = try #require(provider.model.maxOutputTokens)
                            #expect(call.maxTokens <= modelCeiling)
                        }
                    }
                    // Opening the live ledger is a writer takeover, not a read-only probe.
                    // Verify exact durable bytes on an owned copy so subsequent turns keep
                    // the actual engine's authority and the original reopen assertions.
                    let liveLedgerURL = f.profile.sessionDirectory.appendingPathComponent("tool-execution-facts-v4.json")
                    let ledgerURL = f.profile.sessionDirectory.appendingPathComponent("budget-reopen-\(UUID().uuidString).json")
                    try FileManager.default.copyItem(at: liveLedgerURL, to: ledgerURL)
                    #expect(try Data(contentsOf: ledgerURL) == Data(contentsOf: liveLedgerURL))
                    let reopened = try ToolExecutionFactLedger(persistenceURL: ledgerURL)
                    #expect(engine.toolExecutionFactLedger.hasDurableAuthority)
                    #expect(reopened.pendingReceipts.isEmpty)
                    #expect(reopened.facts == engine.toolExecutionFactLedger.facts)
                    let facts = reopened.facts.filter { $0.executionIdentity == identity }
                    if scenario == "allowed" {
                        #expect(facts.count == iterations)
                        #expect(facts.map(\.toolCallID) == (1...iterations).map { "\(prefix)-\($0)" })
                        #expect(facts.allSatisfy { $0.status == .succeeded && !$0.receiptID.isEmpty })
                    } else {
                        #expect(facts.isEmpty)
                    }
                    let runID = try AgentLoopChatEngine.generatedContextManifestRunID(for: identity)
                    let receipt = try #require(f.bridge.contextManifestStore.receipt(runID: runID))
                    let manifest = try #require(f.bridge.contextManifestStore.manifest(runID: runID))
                    #expect(manifest.snapshot.sessionID == session.uuidString)
                    #expect(manifest.snapshot.modelID == provider.model.id)
                    #expect(receipt.requestedBudget == (clipped ? 16_384 : 12_288))
                    #expect(f.center.contextLengthTokens == (clipped ? 16_384 : 0))
                    #expect(chat.composerPolicyFacts.grantedCapabilities == permission.grantedCapabilities)
                    snapshots.append(snapshot)
                    print("POLICY3155_ACTUAL clipped=\(clipped) scenario=\(scenario) effort=\(effort.rawValue) iterations=\(calls.count) requestMaxTokens=\(calls.map(\.maxTokens)) receipts=\(facts.count) contextBudget=\(receipt.requestedBudget) execution=\(identity.operationID)")
                }
                #expect(snapshots.map(\.effort) == [.low, .standard, .high])
                #expect(Set(snapshots.map(\.turnID)).count == 3)
                #expect(Set(snapshots.map(\.taskID)).count == 3)
                #expect(Set(snapshots.map(\.attemptID)).count == 3)
                chat.turnPromptPreprocessPauseForTests = nil
            }
        }
    }

    @Test func threeEffortsHonorActualGrowingContextCeiling3155() async throws {
        guard let parent = ProcessInfo.processInfo.environment["POLICY3155_SETTINGS_CHILD_PARENT_PID"] else {
            try runWithOwnedSettingsProcess("threeEffortsHonorActualGrowingContextCeiling3155")
            return
        }
        #expect(try #require(Int32(parent)) != getpid())
        for (effort, iterations, unconstrainedTokens) in [
            (ComposerEffort.low, 5, 6_144), (.standard, 10, 12_288), (.high, 15, 16_384)
        ] {
            let f = try await makeFixture(contextLength: 4_096)
            defer { f.cleanup() }
            let provider = Policy08AppProvider3155(directory: f.allowed,
                prefix: "growing3155-\(effort.rawValue)", clipped: false, growingContext: true)
            try admit(provider, fixture: f)
            var selection = f.center.composerPolicy
            selection.mode = .auto
            selection.approvalScope = .request
            selection.effort = effort
            f.center.composerPolicy = selection
            let chat = f.bridge.chat
            let session = try #require(chat.activeSessionID)
            chat.draftText = "observe the owned current context ceiling"
            chat.submitComposer()
            let identity = try #require(chat.activeExecutionIdentity(for: session))
            let task = try #require(chat.turnTaskForTests(sessionID: session))
            let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
            await task.value
            #expect(!chat.isStreaming)
            #expect(chat.lastComposerSubmissionSnapshot?.effort == effort)
            #expect(chat.terminalReceipt(for: identity)?.outcome == .failed)
            let calls = provider.calls
            let first = try #require(calls.first)
            // Independent real-request constraints, not a call to the profile
            // or App budget decision under test. A later request must observe
            // the smaller remaining window as actual native history grows.
            #expect(calls.count > 1 && calls.count <= iterations)
            #expect(first.maxTokens > 0 && first.maxTokens < unconstrainedTokens)
            #expect(calls.dropFirst().contains { $0.maxTokens < first.maxTokens })
            let modelCeiling = try #require(provider.model.maxOutputTokens)
            for (index, call) in calls.enumerated() {
                let cost = try #require(AgentLoopChatEngine.estimatedContextCost(
                    call.messages, systemPrompt: call.systemPrompt))
                #expect(call.maxTokens > 0 && cost + call.maxTokens <= 4_096)
                #expect(call.maxTokens < modelCeiling)
                #expect(call.messages.filter { $0.role == .tool }.count == index)
                #expect(call.tools.contains("file_read"))
            }
            #expect(provider.streamingCalls == 0)
            let reopened = try ToolExecutionFactLedger(persistenceURL:
                f.profile.sessionDirectory.appendingPathComponent("tool-execution-facts-v4.json"))
            #expect(reopened.pendingReceipts.isEmpty)
            #expect(reopened.facts == engine.toolExecutionFactLedger.facts)
            let facts = reopened.facts.filter { $0.executionIdentity == identity }
            #expect(facts.count == calls.count)
            #expect(facts.allSatisfy { $0.status == .succeeded && !$0.receiptID.isEmpty })
            let runID = try AgentLoopChatEngine.generatedContextManifestRunID(for: identity)
            #expect(f.bridge.contextManifestStore.receipt(runID: runID)?.requestedBudget == 4_096)
            let assistant = try #require(chat.messages.last(where: { $0.role == .assistant }))
            let exhausted = assistant.content.contains(AgentLoopError.outputTokenCeilingExhausted.localizedDescription)
            let iterationLimited = assistant.content.contains(AgentLoopError.maxIterationsExceeded(iterations).localizedDescription)
            // C batch C3/C10: occupancy >= 95% with nothing reducible ends in
            // contextWindowFull instead of an exhausted-style small request. The
            // message embeds a percentage, so match the exact localized text of the
            // same AgentLoopError over 95...120 (no dependence on rounding/locale).
            let windowFull = (95...120).contains { pct in
                assistant.content.contains(
                    AgentLoopError.contextWindowFull(fraction: Double(pct) / 100).localizedDescription)
            }
            let lastCall = try #require(calls.last)
            let lastCost = try #require(AgentLoopChatEngine.estimatedContextCost(
                lastCall.messages, systemPrompt: lastCall.systemPrompt))
            let lastRequestFraction = Double(lastCost) / 4_096
            let hasUnknownError = assistant.content.contains("CHAT-UNKNOWN")
            #expect(!hasUnknownError)
            switch effort {
            case .low:
                #expect(iterationLimited && calls.count == iterations && lastRequestFraction < 0.80)
            default:
                #expect(windowFull && calls.count < iterations && lastRequestFraction >= 0.75)
            }
            print("POLICY3155_CONTEXT effort=\(effort.rawValue) actualRequests=\(calls.count) maxTokens=\(calls.map(\.maxTokens)) receipts=\(facts.count) exhausted=\(exhausted)")
        }
    }

    @Test func allEffortsRejectOversizedCurrentContextBeforeProvider3155() async throws {
        guard let parent = ProcessInfo.processInfo.environment["POLICY3155_SETTINGS_CHILD_PARENT_PID"] else {
            try runWithOwnedSettingsProcess("allEffortsRejectOversizedCurrentContextBeforeProvider3155")
            return
        }
        #expect(try #require(Int32(parent)) != getpid())
        for effort in [ComposerEffort.low, .standard, .high] {
            let f = try await makeFixture(contextLength: 1_024)
            defer { f.cleanup() }
            let provider = Policy08AppProvider3155(directory: f.allowed,
                prefix: "oversized3155-\(effort.rawValue)", clipped: true)
            try admit(provider, fixture: f)
            var selection = f.center.composerPolicy
            selection.mode = .auto
            selection.effort = effort
            f.center.composerPolicy = selection
            let chat = f.bridge.chat
            let session = try #require(chat.activeSessionID)
            let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
            let before = engine.toolExecutionFactLedger.facts
            let requiredUser = String(repeating: "required current context3155 ", count: 600)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            chat.draftText = requiredUser
            chat.submitComposer()
            let snapshot = try #require(chat.lastComposerSubmissionSnapshot)
            let identity = try #require(chat.activeExecutionIdentity(for: session))
            let task = try #require(chat.turnTaskForTests(sessionID: session))
            await task.value
            #expect(snapshot.effort == effort)
            #expect(!chat.isStreaming)
            #expect(provider.calls.isEmpty && provider.streamingCalls == 0)
            #expect(chat.terminalReceipt(for: identity)?.outcome == .failed)
            #expect(engine.toolExecutionFactLedger.facts == before)
            #expect(engine.toolExecutionFactLedger.pendingReceipts.isEmpty)
            let canonical = try #require(chat.sessionStore?.loadSession(id: session.uuidString))
            #expect(canonical.messages.contains { $0.role == .user && $0.content == requiredUser })
            let assistant = try #require(chat.messages.last(where: { $0.role == .assistant }))
            #expect(assistant.content.contains("当前上下文已超过设置的长度上限，本次请求未执行。请缩短输入或在新会话继续。"))
        }
    }
}
