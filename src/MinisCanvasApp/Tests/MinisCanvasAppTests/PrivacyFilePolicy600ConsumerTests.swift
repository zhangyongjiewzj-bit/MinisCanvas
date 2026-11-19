import Foundation
import Darwin
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Only the model transport is scripted. The gate lets the test observe the
/// identity minted by ChatStore before releasing a real AgentLoop tool call.
private final class Privacy2945ReadProvider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "privacy2945-owned-scripted"
    var runtimeConfigurationMaterial: String? = "privacy2945-owned-scripted-transport-v1"
    var model = LLMModel(id: "privacy2945", displayName: "Privacy2945", provider: "privacy2945-owned-scripted")
    var capabilities: Set<ProviderCapability> { [.tools] }
    private let lock = NSLock()
    private var released = false
    private var items: [[LLMMessage]] = []
    private var parent: ParentRuntimeIdentity?
    private var verified = false
    private var names: [String] = []
    private let callID: String
    private let path: String
    let finalText: String

    init(callID: String, path: String) {
        self.callID = callID; self.path = path
        finalText = "privacy2945-model-final-" + callID
    }
    var requests: [[LLMMessage]] { lock.withLock { items } }
    var parentIdentity: ParentRuntimeIdentity? { lock.withLock { parent } }
    var verifiedParent: Bool { lock.withLock { verified } }
    var toolNames: [String] { lock.withLock { names } }
    func release() { lock.withLock { released = true } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        let first = lock.withLock { () -> Bool in
            items.append(messages)
            if items.count == 1 {
                parent = AgentExecutionContext.current?.parentRuntimeIdentity
                verified = AgentExecutionContext.current?.hasVerifiedParentRuntime == true
                return true
            }
            return false
        }
        if first {
            for _ in 0..<1_000 {
                if lock.withLock({ released }) {
                    let data = try JSONSerialization.data(withJSONObject: [
                        "tool_calls": [["id": callID, "name": "file_read", "input": ["path": path]]]
                    ], options: [.sortedKeys])
                    return LLMResponse(text: String(decoding: data, as: UTF8.self), stopReason: "stop", usage: nil)
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw ToolExecutorError.invalidParameter("Privacy2945 model gate was not released")
        }
        return LLMResponse(text: finalText, stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        lock.withLock { names = tools.map(\.name) }
        return try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                                     maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw ToolExecutorError.invalidParameter("Privacy2945 requires the real tool-loop transport")
    }
}

/// Full production binder under the existing formal-test directory mapping.
/// No disposable-profile guard is changed and no UI, network or real Keychain
/// dependency is constructed. All paths passed to file tools belong to us.
@Suite("TASK600 production file policy consumer", .serialized)
@MainActor
struct PrivacyFilePolicy600ConsumerTests {
    private let unmountedReadRefusal2945 = "PRIVACY2945_SYNTHETIC_UNMOUNTED_READ_DENIED"
    private struct Fixture {
        let root: URL
        let profile: RuntimeIsolationProfile
        let defaults: UserDefaults
        let center: SettingsCenter
        let bridge: BridgeStore
        let workspace: URL
        let mounted: URL
        let outside: URL
        let controller: TurnController
    }

    private func center(root: URL, profile: RuntimeIsolationProfile, defaults: UserDefaults) -> SettingsCenter {
        let keys = KeychainStore(backing: InMemoryKeychainBacking())
        return SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keys,
                                 privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keys),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite(root.lastPathComponent)),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        )
    }

    private func fixture(approvalPolicy: ApprovalPolicy? = nil) async throws -> Fixture {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        // Resolve the existing production defaults only after this real contract
        // is established. Never manufacture a non-disposable profile.
        let profile = RuntimeIsolationProfile.production
        try #require(!profile.isDisposable)
        try #require(profile.sessionDirectory == formal.sessionDirectory)
        for path in [profile.sessionDirectory, profile.settingsDirectory,
                     profile.memoryDirectory, profile.taskDirectory, profile.minisCoreDirectory] {
            try #require(path.standardizedFileURL.path.hasPrefix(formal.rootDirectory.standardizedFileURL.path + "/"))
        }
        let root = formal.temporaryDirectory.appendingPathComponent("Privacy600-" + UUID().uuidString)
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        let center = center(root: root, profile: profile, defaults: defaults)
        if let approvalPolicy {
            center.approvalPolicy = approvalPolicy
            try #require(center.approvalPolicy == approvalPolicy)
        }
        let workspace = root.appendingPathComponent("workspace")
        let mounted = root.appendingPathComponent("mounted")
        let outside = root.appendingPathComponent("outside")
        for path in [workspace, mounted, outside] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try "owned-control".write(to: path.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        }
        #expect(center.setFileAccessAllowedRoot(workspace.path))
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: center.logManager,
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("Workflows")),
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            canvasRuntimeState: .disabled,
            memoryStore: center.memoryStore, memoryProposalConsumer: center.memoryProposalConsumer,
            providerReadinessStore: center.providerReadinessStore,
            taskCenterBindingPersistenceURL: root.appendingPathComponent("task-bindings.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
            }
        )
        try #require(bridge.canvasIfAvailable == nil)
        ProductionOrchestrationDefaults.bindFileAccessSettings(to: bridge, settings: center, profile: profile)
        try #require(center.onFileAccessSettingsChanged != nil)
        await ProductionOrchestrationDefaults.attachCurrentProductionConfiguration(
            to: bridge, settings: center, profile: profile,
            childConcurrencySelection: center.childConcurrencySelection).value
        // The formal SessionStore is shared across cases; restored sessions may
        // belong to a preceding native-project case. Start this fixture from
        // its own ordinary global source using the real production entry.
        bridge.chat.applyNewSession(title: "owned Privacy600 task source")
        let id = try #require(bridge.chat.activeSessionID).uuidString
        let store = try #require(bridge.chat.sessionStore)
        if store.loadSession(id: id) == nil { _ = try store.createSession(id: id, title: "owned Privacy600 task source") }
        try #require(store.directory == profile.sessionDirectory)
        let result = Fixture(root: root, profile: profile, defaults: defaults, center: center, bridge: bridge,
                             workspace: workspace, mounted: mounted, outside: outside, controller: TurnController())
        try await requireCommittedFileComposition(result, settings: center)
        return result
    }

    /// The Settings callback starts an asynchronous production reattachment.
    /// A durable Settings commit is not evidence that the new Builtin/Goal
    /// wrappers have been published. Observe both real consumers before a
    /// request; never weaken the later denial or stale-turn assertions.
    private func requireCommittedFileComposition(
        _ f: Fixture, settings: SettingsCenter,
        replacing previous: BuiltinToolExecutor? = nil
    ) async throws {
        let mounted = Set(settings.effectiveMountedFolders)
        let denied = Set(settings.runtimeDeniedRoots)
        for _ in 0..<300 {
            if let builtin = f.bridge.productionBuiltinToolExecutor,
               previous == nil || builtin !== previous,
               builtin.allowedRoot.path == f.workspace.standardizedFileURL.path,
               Set(builtin.additionalAllowedRoots.map(\.path)) == mounted,
               denied.isSubset(of: Set(builtin.deniedRoots.map(\.path))),
               let engine = f.bridge.chat.agentEngine as? AgentLoopChatEngine,
               let goal = policy(engine.composedExecutor)?.goal,
               Set(goal.fileRoots) == mounted.union([f.workspace.standardizedFileURL.path]) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let builtin = f.bridge.productionBuiltinToolExecutor
        let engine = f.bridge.chat.agentEngine as? AgentLoopChatEngine
        let goalRoots = engine.flatMap { policy($0.composedExecutor)?.goal.fileRoots } ?? []
        Issue.record("Production file composition did not commit: mounted=\(mounted), actualMounted=\(builtin?.additionalAllowedRoots.map(\.path) ?? []), denied=\(denied), actualDenied=\(builtin?.deniedRoots.map(\.path) ?? []), goalRoots=\(goalRoots)")
        throw ToolExecutorError.invalidParameter("Production file composition did not commit")
    }

    private func turn(_ f: Fixture, phase: String,
                      body: (AgentLoopChatEngine) async throws -> Void) async throws -> String {
        let controller = f.controller
        let handle = await controller.beginTurn()
        let source = try #require(f.bridge.chat.activeSessionID).uuidString
        let task = "privacy600-task-\(handle.turnID)"
        let context = AgentExecutionContextSnapshot(
            provider: MockProvider.shared, approvalGate: nil, turnController: controller,
            currentConversationID: source, makeChildBudget: nil,
            deadline: Date().addingTimeInterval(60), parentTurnHandle: handle,
            parentRuntimeIdentity: ParentRuntimeIdentity(sessionID: source, conversationID: source,
                turnID: "turn-handle:\(handle.turnID)", taskID: task, actorID: "app"))
        try #require(context.hasVerifiedParentRuntime)
        let captured = try #require(f.bridge.chat.agentEngine as? AgentLoopChatEngine)
        let builtin = try #require(f.bridge.productionBuiltinToolExecutor)
        #expect(builtin.allowedRoot.path == f.workspace.standardizedFileURL.path)
        print("PRIVACY600_TURN phase=\(phase) task=\(task) parentTurn=\(handle.turnID) roots=\(builtin.additionalAllowedRoots.map(\.path))")
        do {
            try await AgentExecutionContext.$current.withValue(context) { try await body(captured) }
            await handle.finish()
        } catch {
            await handle.finish()
            throw error
        }
        return task
    }

    private func reject(_ engine: AgentLoopChatEngine, path: URL, deniedInsideAllowedRoot: Bool = false) async {
        let refusal: ToolExecutorError = deniedInsideAllowedRoot
            ? .invalidParameter(ToolExecutorError.pathViolation(path.path).localizedDescription) : .invalidParameter(PolicyEnforcedToolExecutorError.policyViolation(.fileRootNotAllowed).localizedDescription)
        await #expect(throws: refusal) { _ = try await engine.composedExecutor.execute(name: "file_read", input: ["path": path.path]) }
        await #expect(throws: refusal) { _ = try await engine.composedExecutor.execute(name: "file_write", input: ["path": path.path, "content": "forbidden", "create_dirs": true]) }
        await #expect(throws: refusal) { _ = try await engine.composedExecutor.execute(name: "file_edit", input: ["path": path.path, "old_string": "owned-control", "new_string": "forbidden"]) }
        print("PRIVACY600_REFUSAL tools=file_read,file_write,file_edit path=\(path.path) expected=\(deniedInsideAllowedRoot ? "pathViolation" : "fileRootNotAllowed")")
    }

    private func reattachReloaded(_ f: Fixture) async throws -> SettingsCenter {
        let reloaded = center(root: f.root, profile: f.profile, defaults: f.defaults)
        ProductionOrchestrationDefaults.bindFileAccessSettings(to: f.bridge, settings: reloaded, profile: f.profile)
        try #require(reloaded.onFileAccessSettingsChanged != nil)
        let previous = f.bridge.productionBuiltinToolExecutor
        await ProductionOrchestrationDefaults.attachCurrentProductionConfiguration(
            to: f.bridge, settings: reloaded, profile: f.profile,
            childConcurrencySelection: reloaded.childConcurrencySelection).value
        try await requireCommittedFileComposition(f, settings: reloaded, replacing: previous)
        return reloaded
    }

    private func policy(_ executor: any ToolExecutor) -> PolicyEnforcedToolExecutor? {
        if let concurrent = executor as? ConcurrentToolLimitingExecutor { return policy(concurrent.baseBox.value) }
        if let recording = executor as? RecordingToolExecutor { return policy(recording.base) }
        return executor as? PolicyEnforcedToolExecutor
    }

    private func until2945(_ observation: @autoclosure () -> Comment, _ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), observation())
    }

    private func ordinaryRead2945(
        _ f: Fixture, path: URL, callID: String, input: String, expectedError: Bool, observeReader: Bool = false,
        beforeModelRelease: (() throws -> Void)? = nil, expectFreshReadDecision: Bool = true,
        freshReadApproval: Bool? = nil, ioProbeOnly: Bool = false
    ) async throws -> (identity: AgentExecutionIdentity, writeback: AgentTurnIdentity, parent: ParentRuntimeIdentity,
                       body: String, opened: Bool, finalText: String,
                       engine: AgentLoopChatEngine, facts: ComposerPolicyFactSource) {
        let chat = f.bridge.chat
        let sessionID = try #require(chat.activeSessionID)
        let provider = Privacy2945ReadProvider(callID: callID, path: path.path)
        // Use the existing production readiness discovery/apply path for
        // this owned scripted transport before the model gate can be reached.
        if chat.chatModelPickerReceipt(providerID: provider.name, modelID: provider.model.id) == nil {
            let checkedAt = Date()
            let lineage = ProviderReadinessLineage.derived(
                providerID: provider.name, modelID: provider.model.id, checkedAt: checkedAt)
            try #require(f.center.providerReadinessStore.upsert([
                ProviderReadinessPersistenceRecord(providerID: provider.name,
                    modelID: provider.model.id, status: .passed, readinessState: .mock,
                    checkedAt: checkedAt, evidenceID: "privacy2945-owned-synthetic",
                    isApplied: false, discoveryReceiptID: lineage.discoveryReceiptID,
                    discoveredAt: lineage.discoveredAt)
            ]))
            try #require(f.center.providerReadinessStore.applyDiscoveredModels(
                providerID: provider.name, modelIDs: [provider.model.id],
                appliedAt: checkedAt.addingTimeInterval(1)).count == 1)
        }
        try #require(chat.chatModelPickerReceipt(
            providerID: provider.name, modelID: provider.model.id) != nil)
        try #require(!ioProbeOnly || observeReader)
        let witness = observeReader ? ReaderWitness(path: path.path) : nil
        var stopped = false
        defer {
            provider.release()
            if !stopped { _ = try? witness?.stopAndRead() }
        }
        try witness?.waitReady()
        chat.streamingProviderOverride = provider
        chat.draftText = input
        chat.submitComposer()
        try await until2945(Comment(rawValue: "Privacy2945 model gate: requests=\(provider.requests.count), streaming=\(chat.isActiveSessionStreaming), activeSessionMatches=\(chat.activeSessionID == sessionID), sessionHasTask=\(chat.turnTaskForTests(sessionID: sessionID) != nil), lifecycleRecoveryFailed=\(f.bridge.toolLifecycleRecoveryFailureURL != nil), invalidSettings=\(chat.lastSubmissionBlockedByInvalidSettings), credentialPreflight=\(chat.isComposerCredentialPreflightPending), attachmentPreflight=\(chat.isComposerAttachmentPreflightPending), pendingApproval=\(f.bridge.approvalCenter.pendingRequest != nil)")) { provider.requests.count == 1 && chat.isActiveSessionStreaming }
        let identity = try #require(chat.activeExecutionIdentity(for: sessionID))
        let writeback = try #require(chat.activeWritebackIdentity(for: sessionID))
        let parent = try #require(provider.parentIdentity)
        let taskEngine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        let taskFacts = chat.composerPolicyFacts
        #expect(provider.verifiedParent)
        #expect(parent.sessionID == sessionID.uuidString)
        #expect(parent.conversationID == sessionID.uuidString)
        #expect(provider.toolNames.contains("file_read"))
        #expect(provider.requests[0].last(where: { $0.role == .user })?.content == input)
        try beforeModelRelease?()
        provider.release()
        if (expectedError && expectFreshReadDecision) || freshReadApproval != nil {
            // H1's outside-read contract requires one fresh call-bound user
            // decision even under autoApprove; it never restores the mount.
            try await until2945("Privacy2945 unmounted read: actual call-bound approval is pending") {
                f.bridge.approvalCenter.pendingRequest != nil
            }
            let request = try #require(f.bridge.approvalCenter.pendingRequest)
            try #require(request.toolName == "file_read")
            try #require(request.callID == callID)
            try #require(request.sessionID == sessionID.uuidString)
            try #require(request.inputDigest == ComposerToolInput(values: ["path": .string(path.path)]).digest)
            try #require(request.identityDigest != nil)
            // 2026-11-16：file_read 卡片可以提供“以后都允许读取此目录”，但只限这一个目录，
            // 且只是一个提议：不等于恢复挂载，本次是否读取仍由这张卡的决定为准。
            if expectedError, let offer = request.persistentAllowOffer {
                try #require(offer.capability == "file_read")
                try #require(offer.summary == path.deletingLastPathComponent().path)
            }
            let approves = freshReadApproval == true
            f.bridge.approvalCenter.resolve(approved: approves,
                reason: approves ? "N07 owned one-call approval" : unmountedReadRefusal2945,
                confirmed: approves, requestID: request.id)
        }
        try await until2945(Comment(rawValue: "Privacy2945 terminal: requests=\(provider.requests.count), streaming=\(chat.isActiveSessionStreaming), matchingReceipt=\(chat.terminalReceipt(for: identity) != nil), pendingApproval=\(f.bridge.approvalCenter.pendingRequest != nil)")) { !chat.isActiveSessionStreaming && chat.terminalReceipt(for: identity) != nil }
        #expect(chat.terminalReceipt(for: identity)?.outcome == .succeeded)
        #expect(provider.requests.count == 2)
        let next = try #require(provider.requests.last)
        let blocks = next.filter { $0.role == .user }.flatMap { message -> [[String: Any]] in
            guard let data = message.content.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            return value.filter { $0["type"] as? String == "tool_result" && $0["tool_use_id"] as? String == callID }
        }
        #expect(blocks.count == 1)
        let block = try #require(blocks.first)
        // IO probes establish open admission, not successful Foundation FIFO
        // decoding. Ordinary calls and every expected refusal keep this gate.
        if !ioProbeOnly || expectedError {
            var failureEvidence = ""
            if block["is_error"] as? Bool != expectedError {
                let branch = ["n07-a-session": "A_SESSION", "n07-a-project": "A_PROJECT",
                              "n07-b-project": "B_PROJECT"][callID] ?? "OTHER"
                // Classify exact production error text only; never emit the text,
                // its path, or infer a typed failure from an arbitrary substring.
                let known: [(String, any Error)] = [
                    ("GRANT_CHANGED", ProjectSessionAppError.grantChanged),
                    ("GRANT_UNAVAILABLE", ProjectSessionAppError.grantUnavailable),
                    ("SOURCE_UNAVAILABLE", ProjectSessionAppError.sourceUnavailable),
                    ("POLICY_FILE_ROOT", PolicyEnforcedToolExecutorError.policyViolation(.fileRootNotAllowed)),
                    ("COMPOSER_PATH", ComposerAuthorizationError.pathOutsideAllowedRoots(path.path)),
                    ("NATIVE_PATH", ToolExecutorError.pathViolation(path.path)),
                    ("NATIVE_PERMISSION", ToolExecutorError.permissionDenied(path.path)),
                    ("NATIVE_NOT_FOUND", ToolExecutorError.fileNotFound(path.path)),
                    ("RESOURCE_SCOPE", ToolExecutorError.resourceScopeInvalid)]
                var category = "UNKNOWN"
                if let content = block["content"] as? String {
                    for (label, error) in known {
                        if content == "Error executing tool file_read: " + error.localizedDescription
                            || content == "Error executing tool file_read: " + ToolExecutorError.invalidParameter(error.localizedDescription).localizedDescription {
                            category = label
                            break
                        }
                    }
                }
                failureEvidence = "syntheticBranch=\(branch) exactErrorTextClass=\(category)"
            }
            #expect(block["is_error"] as? Bool == expectedError, Comment(rawValue: failureEvidence))
        }
        let body = try #require(block["content"] as? String)
        let opened = try witness?.stopAndRead() ?? false
        stopped = true
        return (identity, writeback, parent, body, opened, provider.finalText, taskEngine, taskFacts)
    }

    @Test func nativeProjectAndSessionDirectoryEffectsStayScopedWithoutFreshReadApproval() async throws {
        let f = try await fixture(approvalPolicy: .autoApprove)
        defer { f.bridge.chat.stopAllStreamingForSafety() }
        #expect(f.center.effectiveMountedFolders.isEmpty)
        let handler = try #require(f.bridge.productionProjectSessionHandler)
        let project = f.workspace.appendingPathComponent("n07-native-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let projectID = try handler.authorizeFolderAndOpenSession(project)
        let canonicalProject = try handler.grants.directory(for: handler.grants.resolve(id: projectID)).path
        let chat = f.bridge.chat
        let a = try #require(chat.activeSessionID)
        let b = chat.applyNewSession(title: "N07 same native project")
        chat.setProject(.init(id: projectID, name: "N07 owned native project", workingDirectory: canonicalProject),
                        forSession: b)
        let c = chat.applyNewSession(title: "N07 no native project")
        chat.setProject(nil, forSession: c)
        try #require(chat.applySwitchSession(id: a))
        // Same production post-confirmation service as the original removal case.
        // Neither directory is a global mount or a manually injected executor root.
        try handler.approveAdditionalDirectory(f.outside,
            identity: ProjectSessionGrantRegistry.directoryIdentity(f.outside), sessionID: a.uuidString,
            projectID: projectID, workingDirectory: canonicalProject, persistForProject: false)
        try handler.approveAdditionalDirectory(f.mounted,
            identity: ProjectSessionGrantRegistry.directoryIdentity(f.mounted), sessionID: a.uuidString,
            projectID: projectID, workingDirectory: canonicalProject, persistForProject: true)
        let rows = try #require(f.bridge.approvalCenter.permissionDirectories?())
        let sessionRow = try #require(rows.first { $0.path == f.outside.path && $0.scope == "本会话" })
        let projectRow = try #require(rows.first { $0.path == f.mounted.path && $0.scope == "本项目" })
        let sessionFile = f.outside.appendingPathComponent("note.txt")
        let projectFile = f.mounted.appendingPathComponent("note.txt")
        let sessionDigest = ComposerToolInput(values: ["path": .string(sessionFile.path)]).digest
        let projectDigest = ComposerToolInput(values: ["path": .string(projectFile.path)]).digest
        let expectedFresh: [String: (session: String, digest: String)] = [
            "n07-b-session": (b.uuidString, sessionDigest),
            "n07-c-session": (c.uuidString, sessionDigest),
            "n07-c-project": (c.uuidString, projectDigest),
            "n07-a-session-removed": (a.uuidString, sessionDigest),
            "n07-a-project-removed": (a.uuidString, projectDigest)]
        let center = f.bridge.approvalCenter
        let originalPending = center.onPendingRequestChanged
        var freshRequestIDs = Set<String>()
        center.onPendingRequestChanged = { requestID, sessionID in
            originalPending?(requestID, sessionID)
            guard let requestID else { return }
            guard let request = center.pendingRequest else {
                Issue.record("Unexpected fresh read request in the directory-effect case")
                return
            }
            let callID = request.callID
            guard let expected = expectedFresh[callID] else {
                Issue.record("Unexpected fresh read request in the directory-effect case")
                return
            }
            #expect(request.toolName == "file_read" && request.requestID == requestID)
            #expect(request.sessionID == expected.session && sessionID == expected.session)
            #expect(request.inputDigest == expected.digest)
            freshRequestIDs.insert(requestID)
        }
        defer { center.onPendingRequestChanged = originalPending }
        let aSession = try await ordinaryRead2945(f, path: sessionFile, callID: "n07-a-session",
            input: "Read the owned session directory.", expectedError: false, freshReadApproval: nil)
        let aProject = try await ordinaryRead2945(f, path: projectFile, callID: "n07-a-project",
            input: "Read the owned project directory.", expectedError: false, freshReadApproval: nil)
        #expect(aSession.body.contains("owned-control") && aProject.body.contains("owned-control"))
        try #require(chat.applySwitchSession(id: b))
        let bSession = try await ordinaryRead2945(f, path: sessionFile, callID: "n07-b-session",
            input: "Read the other session directory.", expectedError: true, freshReadApproval: nil)
        let bProject = try await ordinaryRead2945(f, path: projectFile, callID: "n07-b-project",
            input: "Read the same native project's directory.", expectedError: false, freshReadApproval: nil)
        #expect(!bSession.body.contains("owned-control") && bProject.body.contains("owned-control"))
        try #require(chat.applySwitchSession(id: c))
        let cSession = try await ordinaryRead2945(f, path: sessionFile, callID: "n07-c-session",
            input: "Read a foreign session directory.", expectedError: true, freshReadApproval: nil)
        let cProject = try await ordinaryRead2945(f, path: projectFile, callID: "n07-c-project",
            input: "Read a foreign native project's directory.", expectedError: true, freshReadApproval: nil)
        #expect(!cSession.body.contains("owned-control") && !cProject.body.contains("owned-control"))
        try #require(chat.applySwitchSession(id: a))
        let fifo = f.outside.appendingPathComponent("n07-scoped-reader.fifo")
        try pipe(fifo)
        let calibration = try await ordinaryRead2945(f, path: fifo, callID: "n07-scoped-calibration",
            input: "Read the owned session FIFO.", expectedError: false, observeReader: true,
            freshReadApproval: nil, ioProbeOnly: true)
        try #require(calibration.opened)
        let revoke = try #require(center.revokePermissionDirectory)
        let retired = try await ordinaryRead2945(f, path: fifo, callID: "n07-scoped-prepared-revoked",
            input: "Read the same FIFO after preparation.", expectedError: true, observeReader: true,
            beforeModelRelease: { try revoke(sessionRow.id); try revoke(projectRow.id) },
            expectFreshReadDecision: false, freshReadApproval: nil, ioProbeOnly: true)
        #expect(!retired.opened && retired.body.contains(ProjectSessionAppError.grantChanged.localizedDescription))
        #expect(center.permissionDirectories?().contains { $0.id == sessionRow.id || $0.id == projectRow.id } == false)
        let aSessionRemoved = try await ordinaryRead2945(f, path: sessionFile, callID: "n07-a-session-removed",
            input: "Read the removed session directory.", expectedError: true, freshReadApproval: nil)
        let aProjectRemoved = try await ordinaryRead2945(f, path: projectFile, callID: "n07-a-project-removed",
            input: "Read the removed project directory.", expectedError: true, freshReadApproval: nil)
        #expect(!aSessionRemoved.body.contains("owned-control") && !aProjectRemoved.body.contains("owned-control"))
        #expect(freshRequestIDs.count == expectedFresh.count)
        let freshApprovals = f.bridge.approvalReceipts.filter { freshRequestIDs.contains($0.requestID) && $0.status == .approved }
        let freshComposerApprovals = f.bridge.composerApprovalReceipts.filter { freshRequestIDs.contains($0.requestID) }
        #expect(freshApprovals.isEmpty && freshComposerApprovals.isEmpty)
        #expect(f.center.effectiveMountedFolders.isEmpty)
        #expect(try String(contentsOf: sessionFile, encoding: .utf8) == "owned-control")
        #expect(try String(contentsOf: projectFile, encoding: .utf8) == "owned-control")
    }

    @Test(arguments: [false, true])
    func scopedDirectoryRemovalFencesAnAlreadyPreparedOrdinaryTurn(independentFreshApproval: Bool) async throws {
        let f = try await fixture(approvalPolicy: independentFreshApproval ? .alwaysAsk : .autoApprove)
        defer { f.bridge.chat.stopAllStreamingForSafety() }
        let sessionID = try #require(f.bridge.chat.activeSessionID).uuidString
        let handler = try #require(f.bridge.productionProjectSessionHandler)
        // Use the existing production post-confirmation directory seam. Only
        // these owned directories are supplied; no global setting is widened.
        try handler.approveAdditionalDirectory(f.outside,
            identity: ProjectSessionGrantRegistry.directoryIdentity(f.outside), sessionID: sessionID,
            projectID: "session:\(sessionID)", workingDirectory: f.workspace.path, persistForProject: false)
        let path = f.outside.appendingPathComponent("note.txt")
        // 用户已定（对齐 Claude Code）：本会话已授权目录内的读取，即使在“总是询问”模式下
        // 也不弹审批卡；helper 在 freshReadApproval 为 nil 时不处理任何卡片，若弹卡会超时失败。
        let allowed = try await ordinaryRead2945(f, path: path, callID: "n07-before-remove",
            input: "读取本会话已授权目录中的 note.txt。", expectedError: false,
            freshReadApproval: nil)
        #expect(allowed.body.contains("owned-control"))
        #expect(f.bridge.approvalCenter.pendingRequest == nil)
        let row = try #require(f.bridge.approvalCenter.permissionDirectories?().first { $0.path == f.outside.path })
        let revoke = try #require(f.bridge.approvalCenter.revokePermissionDirectory)
        // 撤销授权后，已经准备好的普通回合里的读取必须被围栏拒绝，两种审批模式都一样。
        let regularRefused = try await ordinaryRead2945(f, path: path, callID: "n07-prepared-after-remove",
            input: "读取相同目录中的 note.txt。", expectedError: true,
            beforeModelRelease: { try revoke(row.id) }, expectFreshReadDecision: false,
            freshReadApproval: nil)
        #expect(!regularRefused.body.contains("owned-control"))
        #expect(regularRefused.body.contains(ProjectSessionAppError.grantChanged.localizedDescription))
        #expect(f.bridge.approvalCenter.permissionDirectories?().contains { $0.id == row.id } == false)
        #expect(try String(contentsOf: path, encoding: .utf8) == "owned-control")

        // The existing witness is a FIFO writer, never a passive regular-file
        // observer. Calibrate it on this exact owned FIFO before the negative.
        let fifo = f.outside.appendingPathComponent("n07-prepared-reader.fifo")
        try pipe(fifo)
        try handler.approveAdditionalDirectory(f.outside,
            identity: ProjectSessionGrantRegistry.directoryIdentity(f.outside), sessionID: sessionID,
            projectID: "session:\(sessionID)", workingDirectory: f.workspace.path, persistForProject: false)
        let calibration = try await ordinaryRead2945(f, path: fifo, callID: "n07-fifo-calibration",
            input: "读取获准目录中的合成管道。", expectedError: false, observeReader: true,
            freshReadApproval: nil, ioProbeOnly: true)
        try #require(calibration.opened)
        let fifoRow = try #require(f.bridge.approvalCenter.permissionDirectories?().first { $0.path == f.outside.path })
        let refused = try await ordinaryRead2945(f, path: fifo, callID: "n07-fifo-after-remove",
            input: "再次读取同一合成管道。", expectedError: true, observeReader: true,
            beforeModelRelease: { try revoke(fifoRow.id) }, expectFreshReadDecision: false,
            freshReadApproval: nil, ioProbeOnly: true)
        #expect(!refused.opened)
        #expect(refused.body.contains(ProjectSessionAppError.grantChanged.localizedDescription))
        #expect(try String(contentsOf: path, encoding: .utf8) == "owned-control")
        let fresh = try await ordinaryRead2945(f, path: path, callID: "n07-fresh-after-remove",
            input: "再次请求读取目录中的 note.txt。", expectedError: true)
        #expect(!fresh.body.contains("owned-control"))
    }

    @Test func ordinaryChatStoreTurnAfterUnmountRefusesBeforeReaderAndPersistsNonExecution() async throws {
        // Rooted reads use autoApprove. After unmount, H1's outside-read
        // contract still requires the actual per-call user decision.
        let f = try await fixture(approvalPolicy: .autoApprove)
        do {
        let pipeURL = f.mounted.appendingPathComponent("normal-turn-reader.fifo")
        try pipe(pipeURL)
        // Calibrate this exact FIFO witness separately; Foundation file_read
        // opens FIFOs but does not return their bytes as a regular file.
        let calibration = ReaderWitness(path: pipeURL.path)
        try calibration.waitReady()
        _ = AgentFileChangeRecorder.precheck(toolName: "file_write",
            input: ["path": pipeURL.path, "content": "owned harmless control"])
        let calibrationOpened = try calibration.stopAndRead()
        try #require(calibrationOpened, "Owned FIFO reader calibration must succeed")
        let positiveURL = f.mounted.appendingPathComponent("note.txt")
        let beforeMount = f.bridge.productionBuiltinToolExecutor
        #expect(f.center.mountFolder(f.mounted.path))
        try await requireCommittedFileComposition(f, settings: f.center, replacing: beforeMount)
        let mountedEngine = try #require(f.bridge.chat.agentEngine as? AgentLoopChatEngine)
        let mountedPolicy = try #require(policy(mountedEngine.composedExecutor))
        let mountedFacts = f.bridge.chat.composerPolicyFacts
        #expect(mountedFacts.allowedWriteRoots.contains(f.mounted.path))
        #expect(mountedEngine.toolExecutionFactLedger.hasDurableAuthority)
        let suffix = UUID().uuidString
        let positiveID = "privacy2945-mounted-" + suffix
        let deniedID = "privacy2945-unmounted-" + suffix
        let positive = try await ordinaryRead2945(f, path: positiveURL, callID: positiveID,
            input: "读取已挂载的合成目录文件", expectedError: false)
        #expect(positive.body == "     1\towned-control")
        let positivePolicy = try #require(policy(positive.engine.composedExecutor))
        #expect(positivePolicy.acceptedExecutionCount == 1)
        #expect(positive.facts.allowedWriteRoots.contains(f.mounted.path))
        #expect(positive.facts.revision == mountedFacts.revision)
        let positiveFacts = positive.engine.toolExecutionFactLedger.facts.filter { $0.toolCallID == positiveID }
        #expect(positiveFacts.count == 1)
        let positiveFact = try #require(positiveFacts.first)
        #expect(positiveFact.status == .succeeded)
        #expect(positiveFact.executionIdentity == positive.identity)
        #expect(positiveFact.parentRuntimeIdentity == nil) // This top-level file tool has no child producer binding.

        let beforeUnmount = f.bridge.productionBuiltinToolExecutor
        f.center.unmountFolder(f.mounted.path)
        #expect(!f.center.effectiveMountedFolders.contains(f.mounted.path))
        try await requireCommittedFileComposition(f, settings: f.center, replacing: beforeUnmount)
        let revokedEngine = try #require(f.bridge.chat.agentEngine as? AgentLoopChatEngine)
        let revokedPolicy = try #require(policy(revokedEngine.composedExecutor))
        let revokedFacts = f.bridge.chat.composerPolicyFacts
        #expect(revokedPolicy.goal.goalID != mountedPolicy.goal.goalID)
        #expect(revokedFacts.grantEpoch != mountedFacts.grantEpoch)
        #expect(revokedFacts.leaseID != mountedFacts.leaseID)
        #expect(revokedFacts.revision != mountedFacts.revision)
        #expect(!revokedFacts.allowedWriteRoots.contains(f.mounted.path))
        let denied = try await ordinaryRead2945(f, path: pipeURL, callID: deniedID,
            input: "目录挂载已取消，发起新的普通读取请求", expectedError: true, observeReader: true)
        let deniedPolicy = try #require(policy(denied.engine.composedExecutor))
        #expect(deniedPolicy.goal.goalID != positivePolicy.goal.goalID)
        #expect(denied.facts.grantEpoch != positive.facts.grantEpoch)
        #expect(denied.facts.leaseID != positive.facts.leaseID)
        #expect(denied.facts.revision == revokedFacts.revision)
        #expect(!deniedPolicy.goal.fileRoots.contains(f.mounted.path))
        #expect(!denied.facts.allowedWriteRoots.contains(f.mounted.path))
        #expect(denied.identity != positive.identity)
        #expect(denied.identity.turn.turnID != positive.identity.turn.turnID)
        #expect(denied.parent.taskID != positive.parent.taskID)
        #expect(denied.parent != positive.parent) // Local turn-handle counters may reset with a new composition.
        let refusal = ComposerAuthorizationError.approvalDenied(unmountedReadRefusal2945)
        #expect(denied.body == "Error executing tool file_read: " + refusal.localizedDescription)
        #expect(!denied.opened)
        // Composer preflight is inside the production policy chain, before
        // dispatch/receipt minting. Do not fabricate an executed failure fact.
        #expect(deniedPolicy.acceptedExecutionCount == 0)
        #expect(deniedPolicy.deniedExecutionCount == 0)
        #expect(denied.engine.toolExecutionFactLedger.facts.filter { $0.toolCallID == deniedID }.isEmpty)
        #expect(denied.engine.toolExecutionFactLedger.pendingReceipts.filter { $0.toolCallID == deniedID }.isEmpty)
        let notice = "执行前拦截：1 项工具调用未执行。"
        let deniedMessageID = try #require(UUID(uuidString: denied.writeback.messageID))
        try await until2945("Privacy2945 writeback: matching assistant message contains non-execution notice") {
            f.bridge.chat.messages.contains { $0.id == deniedMessageID && $0.content.contains(notice) }
        }
        #expect(f.bridge.chat.messages.first(where: { $0.id == deniedMessageID })?.content.contains(pipeURL.path) == false)
        // Fresh readers reconstruct the actual persisted transcript and ledger.
        // Opening a ledger claims its writer, so this is after both turns end.
        let reopenedSession = try #require(SessionStore(directory: f.profile.sessionDirectory)
            .loadSession(id: denied.identity.turn.sessionID))
        let persistedRefusals = reopenedSession.messages.filter {
            $0.role == .assistant && $0.content.contains(denied.finalText) && $0.content.contains(notice)
        }
        #expect(persistedRefusals.count == 1)
        #expect(persistedRefusals.first?.content.contains(pipeURL.path) == false)
        let reopenedLedger = try ToolExecutionFactLedger(persistenceURL: f.profile.sessionDirectory
            .appendingPathComponent("tool-execution-facts-v4.json"))
        #expect(reopenedLedger.hasDurableAuthority)
        #expect(reopenedLedger.facts.filter { $0.toolCallID == positiveID } == [positiveFact])
        #expect(reopenedLedger.facts.filter { $0.toolCallID == deniedID }.isEmpty)
        #expect(reopenedLedger.pendingReceipts.filter { $0.toolCallID == deniedID }.isEmpty)
        let reloadedSettings = center(root: f.root, profile: f.profile, defaults: f.defaults)
        #expect(!reloadedSettings.effectiveMountedFolders.contains(f.mounted.path))
        #expect(!reloadedSettings.settings.privacy.mountedFolderPaths.contains(f.mounted.path))
        var info = stat()
        try #require(lstat(pipeURL.path, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFIFO)
        print("PRIVACY2945_NORMAL_TURN mountedTask=\(positive.parent.taskID) revokedTask=\(denied.parent.taskID) mountedGoal=\(positivePolicy.goal.goalID) revokedGoal=\(deniedPolicy.goal.goalID) mountedEpoch=\(positive.facts.grantEpoch) revokedEpoch=\(denied.facts.grantEpoch) mountedLease=\(positive.facts.leaseID) revokedLease=\(denied.facts.leaseID) mountedRevision=\(positive.facts.revision) revokedRevision=\(denied.facts.revision) positiveFileRead=1 fifoCalibration=1 revokedReader=0 call=\(deniedID) executedFact=0 durableNonExecutionNotice=1 freshReopen=1")
        } catch {
            // Retire this fixture's real continuations before another startup
            // recovery can claim the shared formal-test lifecycle journal.
            let turns = f.bridge.chat.cancelStreamingForApplicationExit()
            for turn in turns { await turn.value }
            throw error
        }
        let turns = f.bridge.chat.cancelStreamingForApplicationExit()
        for turn in turns { await turn.value }
    }

    /// POSIX FIFO writer admission witnesses an actual reader opening this
    /// owned path. It is not an access-time inference and never reads content.
    private final class ReaderWitness: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var observed = false
        private let pathForRelease: String
        private let ready = DispatchSemaphore(value: 0)
        private let done = DispatchSemaphore(value: 0)
        init(path: String) {
            pathForRelease = path
            Thread.detachNewThread { [self] in
                ready.signal()
                let descriptor = open(path, O_WRONLY)
                if descriptor >= 0 {
                    let wasStopped = lock.withLock { () -> Bool in
                        if !stopped { observed = true }
                        return stopped
                    }
                    if !wasStopped {
                        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
                        let bytes = Array("owned harmless reader witness".utf8)
                        _ = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
                    }
                    close(descriptor)
                }
                done.signal()
            }
        }
        func waitReady() throws {
            try #require(ready.wait(timeout: .now() + 2) == .success)
            usleep(20_000)
        }
        func stopAndRead() throws -> Bool {
            if done.wait(timeout: .now() + 1) == .success { return lock.withLock { observed } }
            lock.withLock { stopped = true }
            // Release only this owned blocked writer after the actual consumer
            // returned. This deliberate post-check reader is never counted.
            let release = open(pathForRelease, O_RDONLY | O_NONBLOCK)
            try #require(release >= 0)
            defer { close(release) }
            try #require(done.wait(timeout: .now() + 4) == .success)
            return lock.withLock { observed }
        }
    }

    private func pipe(_ path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(mkfifo(path.path, 0o600) == 0)
    }

    @Test func allowedRootAndDeniedChildRouteThroughProductionBinderAndReload() async throws {
        let f = try await fixture()
        let denied = f.workspace.appendingPathComponent("denied")
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        let deniedNote = denied.appendingPathComponent("note.txt")
        try "owned-control".write(to: deniedNote, atomically: true, encoding: .utf8)
        let ownerBeforeDenied = f.bridge.productionBuiltinToolExecutor
        #expect(f.center.addFileAccessDeniedRoot(denied.path))
        try await requireCommittedFileComposition(f, settings: f.center, replacing: ownerBeforeDenied)
        #expect(try #require(f.bridge.productionBuiltinToolExecutor).deniedRoots.map(\.path).contains(denied.path))
        let before = try Data(contentsOf: deniedNote)
        let external = f.outside.appendingPathComponent("note.txt")
        let externalBefore = try Data(contentsOf: external)
        _ = try await turn(f, phase: "allow-deny") { (engine: AgentLoopChatEngine) async throws -> Void in
            let local = f.workspace.appendingPathComponent("new.txt")
            _ = try await engine.composedExecutor.execute(name: "file_write", input: ["path": local.path, "content": "actual-write"])
            #expect(try await engine.composedExecutor.execute(name: "file_read", input: ["path": local.path]) == "     1\tactual-write")
            let overwrite = f.workspace.appendingPathComponent("note.txt")
            // 覆盖已有文件前必须先读（2026-11-16）。
            _ = try await engine.composedExecutor.execute(name: "file_read", input: ["path": overwrite.path])
            _ = try await engine.composedExecutor.execute(name: "file_write", input: ["path": overwrite.path, "content": "actual-overwrite"])
            #expect(try await engine.composedExecutor.execute(name: "file_read", input: ["path": overwrite.path]) == "     1\tactual-overwrite")
            await reject(engine, path: external)
            await reject(engine, path: deniedNote, deniedInsideAllowedRoot: true)
            await reject(engine, path: denied.appendingPathComponent("nested/new.txt"), deniedInsideAllowedRoot: true)
        }
        // The real production callback hops to MainActor. Wait for its
        // recorded value, then prove permitted old-content capture remains
        // reachable through the same composed tool chain.
        let overwrittenPath = f.workspace.appendingPathComponent("note.txt").path
        for _ in 0..<100 {
            if f.bridge.actionHistory.records.contains(where: { $0.fileChange?.path == overwrittenPath }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let overwriteRecord = try #require(f.bridge.actionHistory.records.first(where: { $0.fileChange?.path == overwrittenPath }))
        let overwriteChange = try #require(overwriteRecord.fileChange)
        #expect(overwriteRecord.succeeded)
        #expect(overwriteChange.kind == .overwritten)
        #expect(overwriteChange.diffText.contains("-owned-control"))
        #expect(overwriteChange.diffText.contains("+actual-overwrite"))
        #expect(!overwriteChange.diffIsPartial)
        #expect(AgentFileChangeRecorder.authorizedPrecheckInput(toolName: "file_write", input: ["path": overwrittenPath], owner: nil) == nil)
        print("PRIVACY600_ALLOWED_DIFF actual-overwrite=true old-content-captured=true partial=false")
        let reloaded = try await reattachReloaded(f)
        #expect(reloaded.fileAccessAllowedRoot == f.workspace.path)
        #expect(reloaded.fileAccessDeniedRoots.contains(denied.path))
        _ = try await turn(f, phase: "reloaded-allow-deny") { (engine: AgentLoopChatEngine) async throws -> Void in
            #expect(try await engine.composedExecutor.execute(name: "file_read", input: ["path": f.workspace.appendingPathComponent("new.txt").path]) == "     1\tactual-write")
            await reject(engine, path: deniedNote, deniedInsideAllowedRoot: true)
            await reject(engine, path: external)
        }
        #expect(try Data(contentsOf: deniedNote) == before)
        #expect(try Data(contentsOf: external) == externalBefore)
        #expect(!FileManager.default.fileExists(atPath: denied.appendingPathComponent("nested").path))
    }

    @Test func committedUnmountFreezesANewTaskAndPersistsRevocation() async throws {
        let f = try await fixture()
        let external = f.mounted.appendingPathComponent("note.txt")
        let before = try Data(contentsOf: external)
        let ownerBeforeMount = f.bridge.productionBuiltinToolExecutor
        #expect(f.center.mountFolder(f.mounted.path))
        try await requireCommittedFileComposition(f, settings: f.center, replacing: ownerBeforeMount)
        #expect(SettingsStore(directory: f.root.appendingPathComponent("settings")).settings.privacy.mountedFolderPaths == [f.mounted.path])
        let mountedOwner = try #require(f.bridge.productionBuiltinToolExecutor)
        let first = try await turn(f, phase: "mounted") { (engine: AgentLoopChatEngine) async throws -> Void in
            let frozen = try #require(policy(engine.composedExecutor))
            let frozenGoal = frozen.goal
            #expect(frozenGoal.fileRoots.contains(f.mounted.path))
            #expect(try await engine.composedExecutor.execute(name: "file_read", input: ["path": external.path]) == "     1\towned-control")
            f.center.unmountFolder(f.mounted.path)
            try await requireCommittedFileComposition(f, settings: f.center, replacing: mountedOwner)
            let later = try #require(f.bridge.chat.agentEngine as? AgentLoopChatEngine)
            let nextPolicy = try #require(policy(later.composedExecutor))
            #expect(nextPolicy.goal.goalID != frozenGoal.goalID)
            #expect(!nextPolicy.goal.fileRoots.contains(f.mounted.path))
            #expect(frozen.goal == frozenGoal)
            // Immutable old policy survives the reattach; the existing App
            // callback freshness guard still refuses a late action.
            await #expect(throws: ToolExecutorError.invalidParameter("对话 回调已过期，拒绝晚到结果")) {
                _ = try await engine.composedExecutor.execute(name: "file_read", input: ["path": external.path])
            }
            print("PRIVACY600_FROZEN oldGoal=\(frozenGoal.goalID) nextGoal=\(nextPolicy.goal.goalID) oldRootsRetained=true nextRootsRevoked=true")
        }
        #expect(SettingsStore(directory: f.root.appendingPathComponent("settings")).settings.privacy.mountedFolderPaths.isEmpty)
        let currentOwner = f.bridge.productionBuiltinToolExecutor
        #expect(currentOwner !== mountedOwner)
        let second = try await turn(f, phase: "unmounted-new-task") { (engine: AgentLoopChatEngine) async throws -> Void in
            #expect(try await engine.composedExecutor.execute(name: "file_read", input: ["path": f.workspace.appendingPathComponent("note.txt").path]) == "     1\towned-control")
            await reject(engine, path: external)
            await reject(engine, path: f.mounted.appendingPathComponent("new/new.txt"))
        }
        #expect(first != second)
        let reloaded = try await reattachReloaded(f)
        #expect(reloaded.effectiveMountedFolders.isEmpty)
        let third = try await turn(f, phase: "reloaded-revoked") { (engine: AgentLoopChatEngine) async throws -> Void in await reject(engine, path: external) }
        #expect(third != first && third != second)
        let ownerBeforeNewGrant = f.bridge.productionBuiltinToolExecutor
        #expect(reloaded.mountFolder(f.mounted.path))
        try await requireCommittedFileComposition(f, settings: reloaded, replacing: ownerBeforeNewGrant)
        _ = try await turn(f, phase: "new-grant") { (engine: AgentLoopChatEngine) async throws -> Void in
            #expect(try await engine.composedExecutor.execute(name: "file_read", input: ["path": external.path]) == "     1\towned-control")
        }
        #expect(try Data(contentsOf: external) == before)
        #expect(!FileManager.default.fileExists(atPath: f.mounted.appendingPathComponent("new").path))
    }

    @Test func ownedReaderWitnessHasAPositiveCalibration() async throws {
        let f = try await fixture()
        let path = f.workspace.appendingPathComponent("positive.pipe")
        try pipe(path)
        let witness = ReaderWitness(path: path.path)
        try witness.waitReady()
        _ = AgentFileChangeRecorder.precheck(toolName: "file_write", input: ["path": path.path, "content": "owned harmless control"])
        let read = try witness.stopAndRead()
        try #require(read, "PARTIAL: this filesystem/Foundation cannot expose an actual FIFO reader; no zero-reader claim is admissible")
        print("PRIVACY600_IO_CALIBRATION path=\(path.path) actual-reader=1")
    }

    enum RejectedPath: CaseIterable, Sendable { case outside, nestedDenied, revoked, symlinkEscape }

    // The owned FIFO witnesses a real reader open for file_read as well as
    // mutation prechecks. Keep the original production Binder and turn IDs.
    @Test(arguments: RejectedPath.allCases, ["file_read", "file_write", "file_edit"])
    func rejectedFileMutationNeverOpensAnOldContentReader(location: RejectedPath, tool: String) async throws {
        let f = try await fixture()
        var mountedTask: String?
        var mountedGoalID: UUID?
        var revokedGoalID: UUID?
        let physical: URL
        var requested: URL
        switch location {
        case .outside, .symlinkEscape:
            physical = f.outside.appendingPathComponent("rejected.pipe")
            requested = physical
        case .nestedDenied:
            physical = f.workspace.appendingPathComponent("denied/rejected.pipe")
            requested = physical
        case .revoked:
            physical = f.mounted.appendingPathComponent("rejected.pipe")
            requested = physical
        }
        try pipe(physical)
        if location == .nestedDenied {
            let previous = f.bridge.productionBuiltinToolExecutor
            #expect(f.center.addFileAccessDeniedRoot(physical.deletingLastPathComponent().path))
            try await requireCommittedFileComposition(f, settings: f.center, replacing: previous)
        }
        if location == .symlinkEscape {
            try FileManager.default.createSymbolicLink(at: f.workspace.appendingPathComponent("portal"), withDestinationURL: f.outside)
            requested = f.workspace.appendingPathComponent("portal/rejected.pipe")
        }
        if location == .revoked {
            let previous = f.bridge.productionBuiltinToolExecutor
            #expect(f.center.mountFolder(f.mounted.path))
            try await requireCommittedFileComposition(f, settings: f.center, replacing: previous)
            let granted = try #require(f.bridge.chat.agentEngine as? AgentLoopChatEngine)
            let grantedGoal = try #require(policy(granted.composedExecutor)).goal
            mountedGoalID = grantedGoal.goalID
            #expect(grantedGoal.fileRoots.contains(f.mounted.path))
            mountedTask = try await turn(f, phase: "witness-before-unmount") { (engine: AgentLoopChatEngine) async throws -> Void in
                #expect(try await engine.composedExecutor.execute(name: "file_read", input: ["path": f.mounted.appendingPathComponent("note.txt").path]) == "     1\towned-control")
            }
            let grantedOwner = f.bridge.productionBuiltinToolExecutor
            f.center.unmountFolder(f.mounted.path)
            try await requireCommittedFileComposition(f, settings: f.center, replacing: grantedOwner)
            #expect(!f.center.effectiveMountedFolders.contains(f.mounted.path))
            let revoked = try #require(f.bridge.chat.agentEngine as? AgentLoopChatEngine)
            let revokedGoal = try #require(policy(revoked.composedExecutor)).goal
            revokedGoalID = revokedGoal.goalID
            #expect(revokedGoal.goalID != grantedGoal.goalID)
            #expect(!revokedGoal.fileRoots.contains(f.mounted.path))
        }
        let target = requested
        let refusal: ToolExecutorError = location == .nestedDenied
            ? .invalidParameter(ToolExecutorError.pathViolation(target.path).localizedDescription) : .invalidParameter(PolicyEnforcedToolExecutorError.policyViolation(.fileRootNotAllowed).localizedDescription)
        let refusedTask = try await turn(f, phase: "zero-reader-\(location)-\(tool)") { (engine: AgentLoopChatEngine) async throws -> Void in
            #expect(try await engine.composedExecutor.execute(name: "file_read", input: ["path": f.workspace.appendingPathComponent("note.txt").path]) == "     1\towned-control")
            let witness = ReaderWitness(path: physical.path)
            try witness.waitReady()
            let input: [String: String] = tool == "file_read"
                ? ["path": target.path]
                : ["path": target.path, "content": "forbidden", "old_string": "owned", "new_string": "forbidden"]
            await #expect(throws: refusal) {
                _ = try await engine.composedExecutor.execute(name: tool, input: input)
            }
            let read = try witness.stopAndRead()
            #expect(!read)
            print("PRIVACY600_IO_REFUSAL location=\(location) tool=\(tool) actual-reader=\(read ? 1 : 0)")
        }
        if location == .revoked {
            let grantGoal = try #require(mountedGoalID)
            let deniedGoal = try #require(revokedGoalID)
            let priorTask = try #require(mountedTask)
            #expect(refusedTask != priorTask)
            print("PRIVACY600_REVOKED_READ grant-goal=\(grantGoal) revoked-goal=\(deniedGoal) mounted-task=\(priorTask) refusal-task=\(refusedTask) data-root=\(f.root.path) refusal=\(refusal)")
        }
        var info = stat()
        try #require(lstat(physical.path, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFIFO)
    }

    @Test(arguments: ["file_write", "file_edit"])
    func capturedActiveTurnCannotReadOldContentAfterUnmountRebind(tool: String) async throws {
        let f = try await fixture()
        let target = f.mounted.appendingPathComponent("stale-captured.pipe")
        try pipe(target)
        let ownerBeforeMount = f.bridge.productionBuiltinToolExecutor
        #expect(f.center.mountFolder(f.mounted.path))
        try await requireCommittedFileComposition(f, settings: f.center, replacing: ownerBeforeMount)
        let oldOwner = try #require(f.bridge.productionBuiltinToolExecutor)
        _ = try await turn(f, phase: "captured-active-unmount-\(tool)") { (captured: AgentLoopChatEngine) async throws -> Void in
            #expect(try await captured.composedExecutor.execute(name: "file_read", input: ["path": f.mounted.appendingPathComponent("note.txt").path]) == "     1\towned-control")
            let frozen = try #require(policy(captured.composedExecutor)).goal
            f.center.unmountFolder(f.mounted.path)
            try await requireCommittedFileComposition(f, settings: f.center, replacing: oldOwner)
            #expect(AgentExecutionContext.current?.hasVerifiedParentRuntime == true)
            #expect(f.bridge.productionBuiltinToolExecutor !== oldOwner)
            #expect(frozen.fileRoots.contains(f.mounted.path))
            let current = try #require(f.bridge.chat.agentEngine as? AgentLoopChatEngine)
            #expect(!((try #require(policy(current.composedExecutor))).goal.fileRoots.contains(f.mounted.path)))
            let witness = ReaderWitness(path: target.path)
            try witness.waitReady()
            let stale = ToolExecutorError.invalidParameter(SafetyRuntimeAdmissionError.staleRuntime(
                tool == "file_read" ? .chat : .browserTerminalSideEffects).localizedDescription)
            await #expect(throws: stale) {
                _ = try await captured.composedExecutor.execute(name: tool, input: ["path": target.path, "content": "forbidden", "old_string": "owned", "new_string": "forbidden"])
            }
            let read = try witness.stopAndRead()
            #expect(!read)
            print("PRIVACY618_STALE_ACTIVE tool=\(tool) oldGoal=\(frozen.goalID) verifiedActiveParent=true typed-stale-refused=true actual-reader=\(read ? 1 : 0)")
            await reject(current, path: target)
        }
        var info = stat()
        try #require(lstat(target.path, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFIFO)
        #expect(SettingsStore(directory: f.root.appendingPathComponent("settings")).settings.privacy.mountedFolderPaths.isEmpty)
    }

    @Test func remountDoesNotReviveCapturedOldTurnsFileRead() async throws {
        let f = try await fixture()
        let target = f.mounted.appendingPathComponent("regranted-old-turn.pipe")
        try pipe(target)
        let beforeMount = f.bridge.productionBuiltinToolExecutor
        #expect(f.center.mountFolder(f.mounted.path))
        try await requireCommittedFileComposition(f, settings: f.center, replacing: beforeMount)
        let mountedOwner = try #require(f.bridge.productionBuiltinToolExecutor)
        _ = try await turn(f, phase: "read-grant-old-turn") { (captured: AgentLoopChatEngine) async throws -> Void in
            #expect(try await captured.composedExecutor.execute(name: "file_read", input: [
                "path": f.mounted.appendingPathComponent("note.txt").path
            ]) == "     1\towned-control")
            let oldGoal = try #require(policy(captured.composedExecutor)).goal
            f.center.unmountFolder(f.mounted.path)
            try await requireCommittedFileComposition(f, settings: f.center, replacing: mountedOwner)
            let revokedOwner = try #require(f.bridge.productionBuiltinToolExecutor)
            #expect(f.center.mountFolder(f.mounted.path))
            try await requireCommittedFileComposition(f, settings: f.center, replacing: revokedOwner)
            let currentEngine = try #require(f.bridge.chat.agentEngine as? AgentLoopChatEngine)
            let newGoal = try #require(policy(currentEngine.composedExecutor)).goal
            #expect(newGoal.goalID != oldGoal.goalID)
            #expect(newGoal.fileRoots.contains(f.mounted.path))
            let witness = ReaderWitness(path: target.path)
            try witness.waitReady()
            let stale = ToolExecutorError.invalidParameter(
                SafetyRuntimeAdmissionError.staleRuntime(.chat).localizedDescription)
            await #expect(throws: stale) {
                _ = try await captured.composedExecutor.execute(name: "file_read", input: ["path": target.path])
            }
            let readObserved = try witness.stopAndRead()
            #expect(!readObserved)
        }
    }

    @Test func freshTaskStartingInsideRevokedOldTurnCannotOpenMountedFile() async throws {
        let f = try await fixture()
        let target = f.mounted.appendingPathComponent("fresh-revoked-read.pipe")
        try pipe(target)
        let beforeMount = f.bridge.productionBuiltinToolExecutor
        #expect(f.center.mountFolder(f.mounted.path))
        try await requireCommittedFileComposition(f, settings: f.center, replacing: beforeMount)
        let mountedOwner = try #require(f.bridge.productionBuiltinToolExecutor)
        let oldTask = try await turn(f, phase: "old-turn-crossing-unmount") { captured in
            let oldContext = try #require(AgentExecutionContext.current)
            let oldIdentity = try #require(oldContext.parentRuntimeIdentity)
            let oldGoal = try #require(policy(captured.composedExecutor)).goal
            #expect(oldGoal.fileRoots.contains(f.mounted.path))
            #expect(try await captured.composedExecutor.execute(
                name: "file_read", input: ["path": f.mounted.appendingPathComponent("note.txt").path]
            ) == "     1\towned-control")

            f.center.unmountFolder(f.mounted.path)
            try await requireCommittedFileComposition(f, settings: f.center, replacing: mountedOwner)
            let fresh = try #require(f.bridge.chat.agentEngine as? AgentLoopChatEngine)
            let freshGoal = try #require(policy(fresh.composedExecutor)).goal
            #expect(freshGoal.goalID != oldGoal.goalID)
            #expect(!freshGoal.fileRoots.contains(f.mounted.path))
            #expect(oldGoal.fileRoots.contains(f.mounted.path))

            // The old context is still on this stack when a distinct parent
            // turn starts. Its frozen goal cannot grant the new task access.
            let newHandle = await f.controller.beginTurn()
            let sessionID = try #require(f.bridge.chat.activeSessionID).uuidString
            let newIdentity = ParentRuntimeIdentity(
                sessionID: sessionID, conversationID: sessionID,
                turnID: "turn-handle:\(newHandle.turnID)",
                taskID: "privacy600-task-\(newHandle.turnID)", actorID: "app"
            )
            let newContext = AgentExecutionContextSnapshot(
                provider: MockProvider.shared, approvalGate: nil,
                turnController: f.controller, currentConversationID: sessionID,
                makeChildBudget: nil, deadline: Date().addingTimeInterval(60),
                parentTurnHandle: newHandle, parentRuntimeIdentity: newIdentity
            )
            #expect(newContext.hasVerifiedParentRuntime)
            #expect(newIdentity != oldIdentity)
            do {
                try await AgentExecutionContext.$current.withValue(newContext) {
                    let witness = ReaderWitness(path: target.path)
                    try witness.waitReady()
                    await #expect(throws: ToolExecutorError.invalidParameter(PolicyEnforcedToolExecutorError.policyViolation(.fileRootNotAllowed).localizedDescription)) {
                        _ = try await fresh.composedExecutor.execute(
                            name: "file_read", input: ["path": target.path]
                        )
                    }
                    let opened = try witness.stopAndRead()
                    #expect(!opened, "revoked fresh task opened the prior mounted file")
                    #expect(try await fresh.composedExecutor.execute(
                        name: "file_read", input: ["path": f.workspace.appendingPathComponent("note.txt").path]
                    ) == "     1\towned-control")
                    print("PRIVACY2481_FRESH_CROSS old=\(oldIdentity.taskID) new=\(newIdentity.taskID) oldGoal=\(oldGoal.goalID) newGoal=\(freshGoal.goalID) revoked-reader=\(opened ? 1 : 0)")
                }
                await newHandle.finish()
            } catch {
                await newHandle.finish()
                throw error
            }
            #expect(AgentExecutionContext.current?.parentRuntimeIdentity == oldIdentity)
            let stale = ToolExecutorError.invalidParameter(
                SafetyRuntimeAdmissionError.staleRuntime(.chat).localizedDescription
            )
            await #expect(throws: stale) {
                _ = try await captured.composedExecutor.execute(
                    name: "file_read", input: ["path": f.mounted.appendingPathComponent("note.txt").path]
                )
            }
        }
        #expect(oldTask == "privacy600-task-1")
        #expect(SettingsStore(directory: f.root.appendingPathComponent("settings"))
            .settings.privacy.mountedFolderPaths.isEmpty)
        var info = stat()
        try #require(lstat(target.path, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFIFO)
    }

    @Test func mountedDeniedChildTraversalAndSymlinkEscapeAreRejectedBeforeMutation() async throws {
        let f = try await fixture()
        let denied = f.mounted.appendingPathComponent("denied")
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        let deniedNote = denied.appendingPathComponent("note.txt")
        try "owned-control".write(to: deniedNote, atomically: true, encoding: .utf8)
        let ownerBeforeMount = f.bridge.productionBuiltinToolExecutor
        #expect(f.center.mountFolder(f.mounted.path))
        try await requireCommittedFileComposition(f, settings: f.center, replacing: ownerBeforeMount)
        let ownerBeforeDenied = f.bridge.productionBuiltinToolExecutor
        #expect(f.center.addFileAccessDeniedRoot(denied.path))
        try await requireCommittedFileComposition(f, settings: f.center, replacing: ownerBeforeDenied)
        let outsideNote = f.outside.appendingPathComponent("note.txt")
        let before = try Data(contentsOf: outsideNote)
        let deniedBefore = try Data(contentsOf: deniedNote)
        try FileManager.default.createSymbolicLink(at: f.workspace.appendingPathComponent("portal"), withDestinationURL: f.outside)
        _ = try await turn(f, phase: "mounted-deny-and-escape") { (engine: AgentLoopChatEngine) async throws -> Void in
            #expect(try await engine.composedExecutor.execute(name: "file_read", input: ["path": f.mounted.appendingPathComponent("note.txt").path]) == "     1\towned-control")
            await reject(engine, path: deniedNote, deniedInsideAllowedRoot: true)
            await reject(engine, path: f.workspace.appendingPathComponent("../outside/note.txt"))
            await reject(engine, path: f.workspace.appendingPathComponent("portal/note.txt"))
            await reject(engine, path: f.workspace.appendingPathComponent("portal/new/new.txt"))
        }
        #expect(try Data(contentsOf: outsideNote) == before)
        #expect(try Data(contentsOf: deniedNote) == deniedBefore)
        #expect(!FileManager.default.fileExists(atPath: f.outside.appendingPathComponent("new").path))
    }

    @Test func genuineOSPermissionRefusalSurfacesThroughActualFileTools() async throws {
        let f = try await fixture()
        let file = f.workspace.appendingPathComponent("locked.txt")
        let original = Data("owned-control".utf8)
        try original.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        var rejected = false
        do { _ = try Data(contentsOf: file) } catch { rejected = true }
        try #require(rejected, "PARTIAL: current UID/volume cannot create a genuine owned EACCES; never count this condition PASS")
        _ = try await turn(f, phase: "real-os-permission-denied") { (engine: AgentLoopChatEngine) async throws -> Void in
            #expect(try await engine.composedExecutor.execute(name: "file_read", input: ["path": f.workspace.appendingPathComponent("note.txt").path]) == "     1\towned-control")
            await #expect(throws: ToolExecutorError.permissionDenied(file.path)) {
                _ = try await engine.composedExecutor.execute(name: "file_read", input: ["path": file.path])
            }
            await #expect(throws: ToolExecutorError.invalidParameter(ToolExecutorError.permissionDenied(file.path).localizedDescription)) {
                _ = try await engine.composedExecutor.execute(name: "file_edit", input: ["path": file.path, "old_string": "owned-control", "new_string": "forbidden"])
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try Data(contentsOf: file) == original)
        print("PRIVACY600_OS_EACCES prerequisite=true actual-file-read-and-edit-refusal-verified")
    }
}
