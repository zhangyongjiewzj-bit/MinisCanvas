import Foundation
import Testing
import MinisCore
import Darwin
@testable import MinisCanvasApp

private struct ApprovingApprovalDelegate: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        .approve
    }
}

/// 沿生产 executor 组合链（Concurrent → Recording → Policy → Builtin）
/// 递归定位 PolicyEnforcedToolExecutor，验证接线位置与可观察行为。
private func findPolicyExecutor(in executor: any ToolExecutor) -> PolicyEnforcedToolExecutor? {
    if let policy = executor as? PolicyEnforcedToolExecutor {
        return policy
    }
    if let concurrent = executor as? ConcurrentToolLimitingExecutor {
        return findPolicyExecutor(in: concurrent.baseBox.value)
    }
    if let recording = executor as? RecordingToolExecutor {
        return findPolicyExecutor(in: recording.base)
    }
    return nil
}

/// SafetyRuntimeToolGate is private to the app module, so inspect its nested
/// ToolExecutor values without coupling the test to a private type.
private func findBuiltinExecutor(in executor: any ToolExecutor) -> BuiltinToolExecutor? {
    if let builtin = executor as? BuiltinToolExecutor {
        return builtin
    }
    if let concurrent = executor as? ConcurrentToolLimitingExecutor {
        return findBuiltinExecutor(in: concurrent.baseBox.value)
    }
    if let recording = executor as? RecordingToolExecutor {
        return findBuiltinExecutor(in: recording.base)
    }
    // SafetyRuntimeToolGate is private to the production module; follow only
    // its private base executor so this probe remains an observation seam.
    for child in Mirror(reflecting: executor).children where child.label == "base" {
        if let nested = child.value as? any ToolExecutor,
           let builtin = findBuiltinExecutor(in: nested) {
            return builtin
        }
    }
    return nil
}

// This suite composes the process-wide SettingsCenter.active owner. Parallel
// cases would replace that owner between a turn's capture and Agent execution.
@Suite("Policy 生产接线", .serialized)
@MainActor
struct ProductionPolicyWiringTests {

    /// SettingsCenter.active is deliberately process-wide. Keep the one real
    /// Provider journey in its own SwiftPM test process so unrelated suites
    /// cannot replace its owner between Composer capture and Agent execution.
    private func runGoalCeilingWithIsolatedSettingsOwner() throws {
        let paths = try FormalTestIsolationPaths.resolveCurrentProcess()
        let formal = try #require(paths)
        let inherited = CommandLine.arguments
        let childArguments: [String]
        if let flag = inherited.firstIndex(of: "--test-bundle-path") {
            try #require(flag + 1 < inherited.count)
            let bundle = inherited[flag + 1]
            try #require(inherited[0].hasSuffix("/usr/libexec/swift/pm/swiftpm-testing-helper"))
            try #require(bundle.hasSuffix("/MinisCanvasAppPackageTests.xctest/Contents/MacOS/MinisCanvasAppPackageTests"))
            childArguments = ["--test-bundle-path", bundle, "--testing-library", "swift-testing", "--filter", "goalCeilingFlowsThroughChatSubmissionAndEnginePreflight"]
        } else {
            // resolveCurrentProcess above validates the standalone host and its complete formal root.
            let host = formal.rootDirectory.deletingLastPathComponent()
                .appendingPathComponent("R13OriginalAppMain.app/Contents/MacOS/MinisCanvasOriginalAppMain")
            try #require(formal.packageName == "MinisCanvasApp" && inherited[0] == host.path)
            try #require(FileManager.default.isExecutableFile(atPath: host.path))
            childArguments = ["--testing-library", "swift-testing", "--no-parallel", "--filter", "goalCeilingFlowsThroughChatSubmissionAndEnginePreflight"]
        }
        let evidence = formal.rootDirectory.appendingPathComponent("policy2457-child-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let log = evidence.appendingPathComponent("child.raw.log")
        try #require(FileManager.default.createFile(atPath: log.path, contents: nil))
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: inherited[0])
        child.arguments = childArguments
        var environment = ProcessInfo.processInfo.environment
        environment["POLICY2457_GOAL_CEILING_CHILD_PARENT_PID"] = String(getpid())
        child.environment = environment
        child.standardOutput = handle
        child.standardError = handle
        let done = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in done.signal() }
        try child.run()
        print("POLICY2457_OWNED_CHILD_STARTED suite=ProductionPolicyWiringTests parentPID=\(getpid()) pid=\(child.processIdentifier)")
        let timeout = done.wait(timeout: .now() + 30) != .success
        if timeout {
            child.terminate()
            if done.wait(timeout: .now() + 2) != .success { kill(child.processIdentifier, SIGKILL) }
        }
        child.waitUntilExit()
        print("POLICY2457_OWNED_CHILD_TERMINATED suite=ProductionPolicyWiringTests parentPID=\(getpid()) pid=\(child.processIdentifier) reason=\(child.terminationReason.rawValue) status=\(child.terminationStatus)")
        try handle.synchronize()
        let raw = try String(contentsOf: log, encoding: .utf8)
        print("POLICY2457_CHILD_RAW path=\(log.path) sha256=\(DeletionGate.fingerprint(Data(raw.utf8))) exit=\(child.terminationStatus)")
        try #require(!timeout && child.terminationStatus == 0)
        try #require(raw.contains("Test goalCeilingFlowsThroughChatSubmissionAndEnginePreflight() passed after"))
        try #require(raw.contains("Test run with 1 test in 1 suite passed after"))
    }

    @Test func goalCeilingFlowsThroughChatSubmissionAndEnginePreflight() async throws {
        if let parentPID = ProcessInfo.processInfo.environment["POLICY2457_GOAL_CEILING_CHILD_PARENT_PID"] {
            let parent = try #require(Int32(parentPID))
            #expect(parent != getpid())
        } else {
            try runGoalCeilingWithIsolatedSettingsOwner()
            return
        }
        let root = try makeRoot()
        let suite = "composer-ceiling-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let log = LogManager(directory: root.appendingPathComponent("logs"))
        let ownedMemory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"),
                keychain: keychain, privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: ownedMemory,
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: log,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp/mcps.json"),
                keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite(suite + ".usage")),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness")))
        defer { withExtendedLifetime(center) {} }
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            logManager: log,
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("Workflows")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            memoryStore: ownedMemory,
            canvasFeatureLane: .phase3NonCanvas
        )
        let defaultsPolicy = ProductionPolicyDefaults(
            budget: 10,
            deadlineHorizon: 3_600,
            autonomyLevel: .l1,
            networkDomains: []
        )
        bridge.attachProductionServices(
            fileAccessAllowedRoot: root,
            sessionDirectory: root.appendingPathComponent("sessions"),
            approvalDelegateOverride: ApprovingApprovalDelegate(),
            policyDefaults: defaultsPolicy,
            externalRunners: [:],
            sessionReadSecretStore: EnvVarStore(directory: root.appendingPathComponent("env"))
        )
        let productionEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let policy = try #require(findPolicyExecutor(in: productionEngine.composedExecutor))
        #expect(policy.goal.autonomyLevel == .l1)
        #expect(bridge.chat.composerPolicyFacts.autonomyCeiling == policy.goal.autonomyLevel)
        bridge.updateApprovalPolicy(.alwaysAsk)
        #expect(bridge.chat.composerPolicyFacts.autonomyCeiling == policy.goal.autonomyLevel)

        // Keep the production AgentLoopChatEngine installed by BridgeStore.
        // The built-in synthetic Mock has a legitimate production provenance
        // receipt and echoes ordinary text, so route validation stays intact.
        bridge.chat.streamingProviderOverride = MockProvider.shared
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request, effort: .standard,
            bypassModeConfirmed: false
        )
        let actualSessionStore = try #require(bridge.chat.sessionStore)
        let actualSessionID = try #require(bridge.chat.activeSessionID)
        #expect(SettingsCenter.active === center)
        #expect(actualSessionStore.directory.isFileURL && center.sessionStore.directory.isFileURL)
        #expect(actualSessionStore.directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            == center.sessionStore.directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents)
        let ownedContextResolution = SettingsCenter.contextTurnSettingsSnapshot(
            for: actualSessionStore, sessionID: actualSessionID.uuidString,
            model: MockProvider.shared.model)
        let ownedContextAccepted: Bool
        switch ownedContextResolution {
        case .accepted: ownedContextAccepted = true
        case .ownerUnavailable:
            ownedContextAccepted = false; Issue.record("owned Policy context owner unavailable")
        case .scopeMismatch:
            ownedContextAccepted = false; Issue.record("owned Policy context scope mismatch")
        case .invalid:
            ownedContextAccepted = false; Issue.record("owned Policy context settings invalid")
        }
        try #require(ownedContextAccepted)
        bridge.chat.draftText = "manual within L1"
        bridge.chat.submitComposer()
        for _ in 0..<100 {
            if !bridge.chat.isStreaming { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!bridge.chat.isStreaming)
        let manualAssistant = try #require(bridge.chat.messages.last(where: { $0.role == .assistant }))
        #expect(manualAssistant.content.contains("收到：manual within L1"), "last=\(manualAssistant.content)")
        #expect(bridge.chat.lastComposerSubmissionSnapshot?.autonomyCeiling == .l1)

        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .autoEdit, approvalScope: .request, effort: .standard,
            bypassModeConfirmed: false
        )
        bridge.chat.draftText = "auto edit above L1"
        bridge.chat.submitComposer()
        for _ in 0..<100 {
            if !bridge.chat.isStreaming { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!bridge.chat.isStreaming)
        #expect(bridge.chat.lastComposerSubmissionSnapshot?.autonomyCeiling == .l1)
        let aboveAssistant = try #require(bridge.chat.messages.last(where: { $0.role == .assistant }))
        #expect(aboveAssistant.content.contains("需要自主权上限 L2，而你的上限是 L1"))
        #expect(!aboveAssistant.content.contains("收到：auto edit above L1"))
        let aboveSnapshot = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        let aboveController = ComposerAuthorizationController(
            snapshot: aboveSnapshot, facts: bridge.chat.composerPolicyFacts
        )
        await #expect(throws: ComposerAuthorizationError.modeExceedsAutonomyCeiling(
            required: .l2, maximum: .l1
        )) {
            try await aboveController.validateSnapshot()
        }

        let facts = bridge.chat.composerPolicyFacts
        let missing = ComposerPolicyFactSource(
            knownCapabilities: facts.knownCapabilities,
            grantedCapabilities: facts.grantedCapabilities,
            allowedWriteRoots: facts.allowedWriteRoots,
            workspaceID: facts.workspaceID,
            revision: facts.revision,
            grantEpoch: facts.grantEpoch,
            leaseID: facts.leaseID,
            expiresAt: facts.expiresAt,
            revoked: facts.revoked
        )
        bridge.chat.configureComposerPolicy(missing)
        if var engine = bridge.chat.agentEngine as? AgentLoopChatEngine {
            engine.updateComposerPolicy(missing)
            bridge.chat.agentEngine = engine
        }
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request, effort: .standard,
            bypassModeConfirmed: false
        )
        bridge.chat.draftText = "missing ceiling"
        bridge.chat.submitComposer()
        for _ in 0..<100 {
            if !bridge.chat.isStreaming { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!bridge.chat.isStreaming)
        // The next top-level task is minted from the composition's frozen
        // policy Goal, not from a manually incomplete previous task's facts.
        // Its real Provider path must retain the L1 ceiling and rotate epoch.
        #expect(bridge.chat.lastComposerSubmissionSnapshot?.autonomyCeiling == .l1)
        #expect(bridge.chat.composerPolicyFacts.autonomyCeiling == .l1)
        #expect(bridge.chat.composerPolicyFacts.grantEpoch != missing.grantEpoch)
        let missingAssistant = try #require(bridge.chat.messages.last(where: { $0.role == .assistant }))
        #expect(missingAssistant.content.contains("收到：missing ceiling"))
        #expect(!missingAssistant.content.contains("Composer user autonomy ceiling is missing"))
        let issuedSnapshot = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        // A genuinely incomplete frozen turn still fails at the original
        // Core authorization boundary. Do not use the live producer to mint
        // this malformed legacy snapshot or to widen any grant.
        let missingSnapshot = ComposerSubmissionSnapshot(
            mode: issuedSnapshot.mode,
            approvalScope: issuedSnapshot.approvalScope,
            effort: issuedSnapshot.effort,
            sessionID: issuedSnapshot.sessionID,
            turnID: issuedSnapshot.turnID,
            taskID: issuedSnapshot.taskID,
            attemptID: issuedSnapshot.attemptID,
            messageID: issuedSnapshot.messageID,
            callID: issuedSnapshot.callID,
            inputDigest: issuedSnapshot.inputDigest,
            workspaceID: issuedSnapshot.workspaceID,
            createdAt: issuedSnapshot.createdAt,
            policyRevision: issuedSnapshot.policyRevision,
            grantEpoch: issuedSnapshot.grantEpoch,
            bypassModeConfirmed: issuedSnapshot.bypassModeConfirmed,
            autonomyCeiling: nil
        )
        let missingController = ComposerAuthorizationController(
            snapshot: missingSnapshot, facts: missing
        )
        await #expect(throws: ComposerAuthorizationError.autonomyCeilingMissing) {
            try await missingController.validateSnapshot()
        }

        // PolicyRuntime bounds are restart/explicit-reattach settings. A new
        // production composition must rotate the Goal and freeze its lowered
        // ceiling, rather than carrying the prior Goal's higher facts forward.
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root,
            sessionDirectory: root.appendingPathComponent("sessions"),
            approvalDelegateOverride: ApprovingApprovalDelegate(),
            policyDefaults: ProductionPolicyDefaults(
                budget: 10, deadlineHorizon: 3_600,
                autonomyLevel: .l0, networkDomains: []
            ),
            externalRunners: [:],
            sessionReadSecretStore: EnvVarStore(directory: root.appendingPathComponent("env"))
        ).value
        let loweredEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let loweredPolicy = try #require(findPolicyExecutor(in: loweredEngine.composedExecutor))
        #expect(loweredPolicy.goal.goalID != policy.goal.goalID)
        #expect(loweredPolicy.goal.autonomyLevel == .l0)
        #expect(bridge.chat.composerPolicyFacts.autonomyCeiling == .l0)
        let staleController = ComposerAuthorizationController(
            snapshot: aboveSnapshot, facts: bridge.chat.composerPolicyFacts
        )
        await #expect(throws: ComposerAuthorizationError.autonomyCeilingMismatch) {
            try await staleController.validateSnapshot()
        }

        bridge.chat.streamingProviderOverride = MockProvider.shared
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request, effort: .standard,
            bypassModeConfirmed: false
        )
        bridge.chat.draftText = "manual above lowered L0"
        bridge.chat.submitComposer()
        for _ in 0..<100 {
            if !bridge.chat.isStreaming { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!bridge.chat.isStreaming)
        let loweredSnapshot = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        #expect(loweredSnapshot.autonomyCeiling == .l0)
        let loweredAssistant = try #require(bridge.chat.messages.last(where: { $0.role == .assistant }))
        #expect(loweredAssistant.content.contains("需要自主权上限 L1，而你的上限是 L0"))
        #expect(!loweredAssistant.content.contains("收到：manual above lowered L0"))
        let loweredController = ComposerAuthorizationController(
            snapshot: loweredSnapshot, facts: bridge.chat.composerPolicyFacts
        )
        await #expect(throws: ComposerAuthorizationError.modeExceedsAutonomyCeiling(
            required: .l1, maximum: .l0
        )) {
            try await loweredController.validateSnapshot()
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProductionPolicyWiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeBridge(root: URL, policyDefaults: ProductionPolicyDefaults = .default) -> BridgeStore {
        let bridge = BridgeStore()
        bridge.attachProductionServices(
            fileAccessAllowedRoot: root,
            sessionDirectory: root,
            approvalDelegateOverride: ApprovingApprovalDelegate(),
            policyDefaults: policyDefaults
        )
        return bridge
    }

    @Test func productionCompositionRootWiresPolicyGateAroundBuiltinExecutor() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let bridge = makeBridge(root: root)
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        try engine.loop.requireApprovalGate()
        let policy = try #require(findPolicyExecutor(in: engine.composedExecutor))
        #expect(String(describing: type(of: policy.base)).contains("SafetyRuntimeToolGate"))
        _ = try #require(findBuiltinExecutor(in: policy.base))
        #expect(policy.goal.allowedCapabilities.contains("file_read"))
        #expect(policy.goal.fileRoots.contains(root.standardizedFileURL.path))
        #expect(policy.currentLease != nil)
    }

    @Test func policyGateRejectsOutOfRootPathWithoutUnderlyingExecution() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("policy-outside-\(UUID().uuidString).txt")
        try "sentinel-content".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        let bridge = makeBridge(root: root)
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let policy = try #require(findPolicyExecutor(in: engine.composedExecutor))

        await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.fileRootNotAllowed)) {
            _ = try await policy.execute(name: "file_read", input: ["path": outside.path])
        }
        #expect(policy.deniedExecutionCount == 1)
        #expect(policy.acceptedExecutionCount == 0)
    }

    @Test func policyGateAllowsInRootPathThroughRealBuiltinExecutor() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("inside.txt")
        try "hello-policy".write(to: file, atomically: true, encoding: .utf8)

        let bridge = makeBridge(root: root)
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let policy = try #require(findPolicyExecutor(in: engine.composedExecutor))

        // ProjectSessionCompositeToolExecutor sits below PolicyRuntime in the
        // production chain. Even an in-root file cannot be read without the
        // Core-created parent-turn source identity.
        await #expect(throws: ProjectSessionAppError.sourceUnavailable) {
            _ = try await policy.execute(name: "file_read", input: ["path": file.path])
        }

        let sessionID = try #require(bridge.chat.activeSessionID?.uuidString)
        let turnController = TurnController()
        let parentTurn = await turnController.beginTurn()
        defer { Task { await parentTurn.finish() } }
        let context = AgentExecutionContextSnapshot(
            provider: MockProvider.shared,
            approvalGate: nil,
            turnController: turnController,
            currentConversationID: sessionID,
            makeChildBudget: nil,
            deadline: nil,
            parentTurnHandle: parentTurn,
            parentRuntimeIdentity: ParentRuntimeIdentity(
                sessionID: sessionID,
                conversationID: sessionID,
                turnID: "turn-handle:\(parentTurn.turnID)",
                taskID: "policy-wiring-parent",
                actorID: "app"
            )
        )
        #expect(context.hasVerifiedParentRuntime)
        let output = try await AgentExecutionContext.$current.withValue(context) {
            try await policy.execute(name: "file_read", input: ["path": file.path])
        }
        #expect(output.contains("hello-policy"))
        #expect(policy.acceptedExecutionCount == 2)
        #expect(policy.deniedExecutionCount == 0)
    }

    // MARK: - S6：生产默认值收紧（budget 1M / distantFuture / l3 / 空域名 → 保守默认）

    @Test func freshProductionPolicyDefaultsUseLevelTwo() {
        #expect(ProductionPolicyDefaults.default.autonomyLevel == .l2)
        #expect(ProductionPolicyDefaults(autonomyLevel: .l1).autonomyLevel == .l1)
    }

    @Test func productionPolicyGoalUsesConservativeDefaults() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let bridge = makeBridge(root: root)
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let policy = try #require(findPolicyExecutor(in: engine.composedExecutor))
        // 预算：有界（不再 1M ≈ 无限）
        #expect(policy.goal.budget > 0)
        #expect(policy.goal.budget < 1_000_000)
        // 时限：有限（不再 .distantFuture）
        #expect(policy.goal.deadline.timeIntervalSinceReferenceDate.isFinite)
        #expect(policy.goal.deadline != .distantFuture)
        // 自主权：低于完整自主（不再 .l3）
        #expect(policy.goal.autonomyLevel < .l3)
        // 网络域名：fail-closed（保持空白名单）
        #expect(policy.goal.networkDomains.isEmpty)
        // lease 生命周期与 goal 对齐（同为有限）
        let lease = try #require(policy.currentLease)
        #expect(lease.expiresAt.timeIntervalSinceReferenceDate.isFinite)
        #expect(lease.expiresAt != .distantFuture)
        #expect(lease.expiresAt == policy.goal.deadline)
    }

    @Test func productionCompositionInstallsBrowserDomainRequestBuilder() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let bridge = makeBridge(root: root, policyDefaults: ProductionPolicyDefaults(
            budget: 10,
            deadlineHorizon: 3_600,
            autonomyLevel: .l1,
            networkDomains: ["allowed.example.com"]
        ))
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let policy = try #require(findPolicyExecutor(in: engine.composedExecutor))
        let concurrent = ConcurrentToolLimitingExecutor(base: engine.composedExecutor, maxConcurrent: 2)
        let turnExecutor = SpeechAvailabilityGatedToolExecutor(base: concurrent, availability: nil)
        #expect(turnExecutor.permitsBrowserDestination(host: "allowed.example.com") == true)
        #expect(turnExecutor.permitsBrowserDestination(host: "unlisted.example.com") == false)
        #expect(policy.requestBuilder("browser", ["url": "https://evil.example.org/x"]).networkDomain == "evil.example.org")
        await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.networkDomainNotAllowed)) {
            _ = try await policy.execute(name: "browser", input: ["url": "https://evil.example.org/x"])
        }
        #expect(policy.deniedExecutionCount == 1)
        #expect(policy.acceptedExecutionCount == 0)
    }

    @Test func explicitPolicyDefaultsOverrideAreHonored() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let bridge = BridgeStore()
        bridge.attachProductionServices(
            fileAccessAllowedRoot: root,
            sessionDirectory: root,
            approvalDelegateOverride: ApprovingApprovalDelegate(),
            policyDefaults: ProductionPolicyDefaults(
                budget: 7_777,
                deadlineHorizon: 3_600,
                autonomyLevel: .l3,
                networkDomains: ["example.com"]
            )
        )
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let policy = try #require(findPolicyExecutor(in: engine.composedExecutor))
        #expect(policy.goal.budget == 7_777)
        #expect(policy.goal.deadline > Date())
        #expect(policy.goal.deadline.timeIntervalSinceReferenceDate.isFinite)
        #expect(policy.goal.autonomyLevel == .l3)
        #expect(policy.goal.networkDomains == ["example.com"])
        let lease = try #require(policy.currentLease)
        #expect(lease.expiresAt == policy.goal.deadline)
    }

    @Test func appCompositionUsesPolicyDefaultsFromTheAgentSettingsSnapshot() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var agentSettings = AgentSettings.default
        agentSettings.policyRuntimeDefaults = ProductionPolicyDefaults(
            budget: 777,
            deadlineHorizon: 125,
            autonomyLevel: .l2,
            networkDomains: ["api.example.com"]
        )
        let bridge = BridgeStore()
        ProductionOrchestrationDefaults.attachProductionServices(
            to: bridge,
            agentSettings: agentSettings,
            fileAccessAllowedRoot: root,
            sessionDirectory: root
        )
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let policy = try #require(findPolicyExecutor(in: engine.composedExecutor))
        #expect(policy.goal.budget == agentSettings.policyRuntimeDefaults.budget)
        #expect(policy.goal.autonomyLevel == agentSettings.policyRuntimeDefaults.autonomyLevel)
        #expect(policy.goal.networkDomains == agentSettings.policyRuntimeDefaults.networkDomains)
        #expect(policy.goal.deadline.timeIntervalSinceNow > 100)
        #expect(policy.goal.deadline.timeIntervalSinceNow < 130)
    }

    @Test func committedUserCeilingRebuildsNextTurnAndBlocksBudgetAndExcessMode() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "Policy558", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled
        )
        let defaults = profile.makeUserDefaults()
        defer {
            if let suite = profile.userDefaultsSuiteName {
                defaults.removePersistentDomain(forName: suite)
            }
            try? profile.cleanupDisposableRoots()
        }
        let keychain = profile.makeKeychainStore()
        let logManager = profile.makeLogManager()
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: EnvVarStore(directory: profile.minisCoreDirectory, keychain: keychain,
                                 privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            logManager: logManager,
            mcpManager: MCPServerManager(
                fileURL: profile.mcpDirectory.appendingPathComponent("mcps.json"),
                keychain: keychain
            ),
            skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(
                directory: profile.providerConfigurationDirectory
            )
        )
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            logManager: logManager,
            workflowStore: WorkflowStore(
                storeDirectory: profile.rootDirectory.appendingPathComponent("Workflows")
            ),
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            memoryStore: center.memoryStore,
            canvasFeatureLane: .phase3NonCanvas
        )
        ProductionOrchestrationDefaults.attachCurrentProductionConfiguration(
            to: bridge, settings: center, profile: profile,
            childConcurrencySelection: center.childConcurrencySelection
        )
        ProductionOrchestrationDefaults.bindPolicyRuntimeDefaults(
            to: bridge, settings: center, profile: profile
        )
        let originalEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let originalPolicy = try #require(findPolicyExecutor(in: originalEngine.composedExecutor))
        #expect(!center.updatePolicyRuntimeDefaults(ProductionPolicyDefaults(
            budget: 0, deadlineHorizon: .infinity,
            autonomyLevel: .l3, networkDomains: ["https://invalid.example"]
        )))
        #expect(bridge.chat.agentEngine as? AgentLoopChatEngine != nil)
        #expect(center.policyRuntimeDefaults == .default)

        // Present a real reusable approval on the Bridge-owned center.
        let approvalCenter = bridge.approvalCenter
        approvalCenter.inlineApprovalEnabled = true
        approvalCenter.inlineHostAvailable = true
        let file = profile.rootDirectory.appendingPathComponent("ceiling-approval.txt")
        try Data("before".utf8).write(to: file)
        func approval(_ id: String) -> ApprovalRequest {
            ApprovalRequest(id: id, toolName: "file_write", inputSummary: "synthetic",
                riskLevel: .high, requiresApproval: true, sessionID: "ceiling-fixture",
                policyRevision: "fixture-revision", grantEpoch: "fixture-epoch",
                filePreview: ApprovalFilePreview.capture(tool: "file_write", input: [
                    "path": file.path, "content": "after"
                ]))
        }
        func rememberApproval() async {
            let first = Task { await approvalCenter.present(approval("initial")) }
            defer { approvalCenter.stopGeneration() }
            for _ in 0..<100 where approvalCenter.pendingRequest == nil { await Task.yield() }
            #expect(approvalCenter.pendingRequest?.id == "initial")
            approvalCenter.rememberSameKindInSession = true
            approvalCenter.resolve(approved: true, confirmed: true)
            approvalCenter.stopGeneration()
            #expect((await first.value).approved)
        }
        func probeApproval(_ id: String, expectedReuse: Bool) async {
            let probe = Task { await approvalCenter.present(approval(id)) }
            for _ in 0..<100 where approvalCenter.pendingRequest == nil { await Task.yield() }
            if approvalCenter.pendingRequest?.id == id { approvalCenter.actionsForPresentedRequest().deny() }
            approvalCenter.stopGeneration()
            #expect((await probe.value).approved == expectedReuse)
        }
        let owner = UUID()
        await rememberApproval()
        bridge.chat.selectInteractiveComposerMode(.auto, owner: owner)
        #expect(bridge.chat.composerPolicySelection.mode == .manual)
        #expect(center.policyRuntimeDefaults.autonomyLevel == .l2)
        await probeApproval("before-confirm", expectedReuse: true)

        let durableWrite = try #require(bridge.chat.persistComposerCeiling)
        bridge.chat.persistComposerCeiling = { _, _ in false }
        await bridge.chat.confirmInteractiveComposerMode(owner: owner)
        #expect(bridge.chat.composerPolicySelection.mode == .manual)
        #expect(center.policyRuntimeDefaults.autonomyLevel == .l2)
        await probeApproval("after-failed-write", expectedReuse: false)

        bridge.chat.persistComposerCeiling = durableWrite
        await rememberApproval()
        bridge.chat.selectInteractiveComposerMode(.auto, owner: owner)
        await bridge.chat.confirmInteractiveComposerMode(owner: owner)
        #expect(bridge.chat.composerPolicySelection.mode == .auto)
        #expect(SettingsStore(directory: profile.settingsDirectory)
            .settings.agent.policyRuntimeDefaults.autonomyLevel == .l3)
        await probeApproval("after-durable-write", expectedReuse: false)
        try #require(center.updatePolicyRuntimeDefaults(.default))
        await bridge.lastChildGovernorSafetyTask?.value

        // Submit through the production ChatStore route, then commit settings
        // synchronously while its accepted turn is still streaming. This
        // preserves the real route's readiness provenance.
        bridge.chat.streamingProviderOverride = MockProvider.shared
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request, effort: .standard,
            bypassModeConfirmed: false
        )
        bridge.chat.draftText = "old turn remains frozen"
        bridge.chat.submitComposer()
        #expect(bridge.chat.isStreaming)
        let oldTurn = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        #expect(oldTurn.autonomyCeiling == .l2)
        #expect(oldTurn.effort == .standard)

        let lowered = ProductionPolicyDefaults(
            budget: 0, deadlineHorizon: 300,
            autonomyLevel: .l0, networkDomains: ["allowed.example.com"]
        )
        #expect(center.updatePolicyRuntimeDefaults(lowered))
        await bridge.lastChildGovernorSafetyTask?.value
        #expect(SettingsStore(directory: profile.settingsDirectory)
            .settings.agent.policyRuntimeDefaults == lowered)
        let nextEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let nextPolicy = try #require(findPolicyExecutor(in: nextEngine.composedExecutor))
        #expect(nextPolicy.goal.goalID != originalPolicy.goal.goalID)
        #expect(originalPolicy.goal.budget == ProductionPolicyDefaults.default.budget)
        #expect(nextPolicy.goal.budget == 0)
        #expect(nextPolicy.goal.autonomyLevel == .l0)
        #expect(nextPolicy.goal.networkDomains == ["allowed.example.com"])
        #expect(nextPolicy.goal.deadline.timeIntervalSinceNow > 270)
        #expect(nextPolicy.currentLease?.expiresAt == nextPolicy.goal.deadline)
        #expect(bridge.chat.composerPolicyFacts.autonomyCeiling == .l0)
        let stillFrozen = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        #expect(stillFrozen.taskID == oldTurn.taskID)
        #expect(stillFrozen.autonomyCeiling == oldTurn.autonomyCeiling)
        #expect(stillFrozen.effort == .standard)
        #expect(bridge.chat.isStreaming)
        for _ in 0..<100 {
            if !bridge.chat.isStreaming { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!bridge.chat.isStreaming)
        await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.budgetExceeded)) {
            _ = try await nextPolicy.execute(
                name: "file_read",
                input: ["path": profile.rootDirectory.appendingPathComponent("missing.txt").path]
            )
        }
        #expect(nextPolicy.acceptedExecutionCount == 0)

        bridge.chat.streamingProviderOverride = MockProvider.shared
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request, effort: .high,
            bypassModeConfirmed: false
        )
        bridge.chat.draftText = "blocked by user L0 ceiling"
        bridge.chat.submitComposer()
        for _ in 0..<100 {
            if !bridge.chat.isStreaming { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!bridge.chat.isStreaming)
        let frozen = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        #expect(frozen.autonomyCeiling == .l0)
        #expect(frozen.effort == .high)
        let assistant = try #require(bridge.chat.messages.last(where: { $0.role == .assistant }))
        #expect(assistant.content.contains("需要自主权上限 L1，而你的上限是 L0"))
        #expect(!assistant.content.contains("收到：blocked by user L0 ceiling"))
        #expect(nextPolicy.acceptedExecutionCount == 0)

        center.markBL6SettingsTransactionUnknown()
        #expect(!center.updatePolicyRuntimeDefaults(.default))
        #expect(center.policyRuntimeDefaults == lowered)
        #expect(bridge.chat.composerPolicyFacts.autonomyCeiling == .l0)
    }

    @Test func newTopLevelSubmissionGetsFreshGoalAfterPriorTaskExpires() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "PolicyTaskGoal", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled
        )
        let root = profile.rootDirectory
        let defaults = profile.makeUserDefaults()
        defer {
            if let suite = profile.userDefaultsSuiteName {
                defaults.removePersistentDomain(forName: suite)
            }
            try? profile.cleanupDisposableRoots()
        }
        let log = profile.makeLogManager()
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            logManager: log,
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("Workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            taskCenterBindingPersistenceURL: root.appendingPathComponent("task-center-binding.json"),
            canvasFeatureLane: .phase3NonCanvas
        )
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root,
            sessionDirectory: profile.sessionDirectory,
            approvalDelegateOverride: ApprovingApprovalDelegate(),
            policyDefaults: ProductionPolicyDefaults(
                budget: 5, deadlineHorizon: 2,
                autonomyLevel: .l1, networkDomains: []
            ),
            externalRunners: [:],
            sessionReadSecretStore: EnvVarStore(directory: root.appendingPathComponent("env"))
        ).value
        bridge.chat.streamingProviderOverride = MockProvider.shared
        bridge.chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request, effort: .standard,
            bypassModeConfirmed: false
        )
        bridge.chat.draftText = "first bounded task"
        bridge.chat.submitComposer()
        let firstSnapshot = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        let firstEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let firstPolicy = try #require(findPolicyExecutor(in: firstEngine.composedExecutor))
        #expect(firstSnapshot.grantEpoch == bridge.chat.composerPolicyFacts.grantEpoch)
        #expect(firstPolicy.goal.budget == 5)
        for _ in 0..<150 where bridge.chat.isStreaming {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!bridge.chat.isStreaming)
        try await Task.sleep(for: .milliseconds(2_100))
        #expect(firstPolicy.goal.deadline < Date())

        bridge.chat.draftText = "second independent task"
        bridge.chat.submitComposer()
        let secondSnapshot = try #require(bridge.chat.lastComposerSubmissionSnapshot)
        let secondEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let secondPolicy = try #require(findPolicyExecutor(in: secondEngine.composedExecutor))
        #expect(secondSnapshot.taskID != firstSnapshot.taskID)
        #expect(secondPolicy.goal.goalID != firstPolicy.goal.goalID)
        #expect(secondPolicy.currentLease?.goalID == secondPolicy.goal.goalID)
        #expect(secondPolicy.goal.deadline > Date())
        #expect(firstPolicy.goal.deadline < Date())
        #expect(secondSnapshot.policyRevision == firstSnapshot.policyRevision)
        #expect(secondSnapshot.grantEpoch != firstSnapshot.grantEpoch)
        for _ in 0..<150 where bridge.chat.isStreaming {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!bridge.chat.isStreaming)
        let secondAssistant = try #require(bridge.chat.messages.last(where: { $0.role == .assistant }))
        #expect(!secondAssistant.content.contains("Composer policy facts expired"))

        let frozenGoalID = secondPolicy.goal.goalID
        bridge.chat.prepareTopLevelTaskPolicy = { _, _, _, _ in false }
        bridge.chat.draftText = "producer must fail closed"
        bridge.chat.submitComposer()
        #expect(!bridge.chat.isStreaming)
        #expect(bridge.chat.messages.last(where: { $0.role == .assistant })?.content
            == "任务策略不可用，本次未向模型发送请求。")
        let afterDenial = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(findPolicyExecutor(in: afterDenial.composedExecutor)?.goal.goalID == frozenGoalID)
    }
}
