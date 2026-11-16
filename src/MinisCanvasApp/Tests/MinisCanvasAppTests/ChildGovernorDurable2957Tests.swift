import Foundation
import Darwin
import Testing
import MinisCore
@testable import MinisCanvasApp

private struct NoChildTools2957: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String {
        throw ToolExecutorError.toolNotConfigured(name)
    }
}

private actor ChildCalls2957 {
    private var names: [String] = []
    private var held: [String: CheckedContinuation<Void, Never>] = [:]
    func enter(_ name: String) async {
        names.append(name)
        await withCheckedContinuation { held[name] = $0 }
    }
    func release(_ name: String) { held.removeValue(forKey: name)?.resume() }
    func observed() -> [String] { names }
}

private struct HeldChild2957: LLMProvider {
    let session: String
    let calls: ChildCalls2957
    var name: String { "owned2957-\(session)" }
    var model: LLMModel
    init(session: String, calls: ChildCalls2957) {
        self.session = session
        self.calls = calls
        self.model = LLMModel(id: "owned2957", displayName: "Owned", provider: "owned2957-\(session)")
    }
    var capabilities: Set<ProviderCapability> { [.streaming] }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        await calls.enter(session)
        return LLMResponse(text: "owned child completed", stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("D-CHILDD production Bridge checkpoint across owned processes", .serialized)
@MainActor
struct ChildGovernorDurable2957Tests {
    private struct FixtureRequest: Codable {
        let root: URL
        let proof: URL
        let parentPID: Int32
        let nonce: String
        let active: Bool
        let gapStage: Int
    }
    private struct FixtureProof: Codable {
        let pid: Int32
        let nonce: String
        let calls: [String]
        let queued: [String]
        let active: Int
        let intentIDs: [String]
        var taskLedgerDigest: String? = nil
    }

    private func makeBridge(_ root: URL) throws -> BridgeStore {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "child2957-composition", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        let defaults = profile.makeUserDefaults()
        let sessions = root.appendingPathComponent("sessions")
        return BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: profile.makeLogManager(),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: sessions),
            sessionStore: SessionStore(directory: sessions),
            canvasRuntimeState: .disabled,
            agentTaskStore: try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json")),
            contextManifestStore: ContextManifestStore(),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("providers")),
            taskCenterBindingPersistenceURL: root.appendingPathComponent("bindings.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
            })
    }

    private func attach(_ bridge: BridgeStore, root: URL) async throws -> ChildConcurrencyGovernor {
        let selection = try ChildConcurrencySelection(
            userSelected: 1, recommended: 1, effective: 1, enabledSessionCount: 1)
        let secretDefaults = try #require(UserDefaults(suiteName: "owned2957-\(UUID().uuidString)"))
        let secrets = EnvVarStore(directory: root.appendingPathComponent("owned-env"),
            keychain: KeychainStore(backing: InMemoryKeychainBacking()),
            privacyStore: EnvVarPrivacyStore(defaults: secretDefaults))
        await bridge.attachProductionServices(fileAccessAllowedRoot: root,
            sessionDirectory: root.appendingPathComponent("sessions"),
            enableOrchestration: true, childConcurrencySelection: selection,
            sessionReadSecretStore: secrets).value
        return try #require(bridge.orchestrationChildGovernor)
    }

    private func producer(_ session: String, bridge: BridgeStore,
                          governor: ChildConcurrencyGovernor, calls: ChildCalls2957,
                          handle: TurnController.TurnHandle, timeout: TimeInterval = 10,
                          activityObserver: (@Sendable (String, Bool) async -> Void)? = nil) -> AgentOrchestrator {
        let provider = HeldChild2957(session: session, calls: calls)
        let parent = ParentRuntimeIdentity(sessionID: session, conversationID: session,
            turnID: "turn-handle:\(handle.turnID)", taskID: "parent-\(session)-\(getpid())", actorID: "owned2957")
        return AgentOrchestrator(provider: provider, toolExecutor: NoChildTools2957(),
            childTimeout: timeout, currentConversationID: session, taskStore: bridge.agentTaskStore, parentID: parent.taskID,
            parentBinding: ParentContextSnapshotV1(providerID: provider.name, modelID: provider.model.id,
                configurationFingerprint: "owned2957-frozen", conversationID: session),
            parentRuntimeIdentity: parent,
            parentGoal: GoalEnvelope(scopeID: "owned2957-\(session)", allowedCapabilities: ["orchestrate"],
                budget: 100, deadline: Date().addingTimeInterval(120), autonomyLevel: .l3),
            parentTurnHandle: handle, runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.streaming],
                allowedToolNames: [], allowedMCPToolNames: []), parentCapabilities: [.streaming],
            childExecutionActivityObserver: activityObserver, childGovernor: governor)
    }

    private func launch(_ producer: AgentOrchestrator, session: String) -> Task<[SubAgentReport], Never> {
        Task { await producer.orchestrate(tasks: [SubAgentTask(
            id: "child-\(session)", title: "Owned \(session)", instructions: "Complete owned \(session)")],
            strategy: .sequential) }
    }

    private func wait(iterations: Int = 1000, _ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<iterations {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }

    private func makeRoot() throws -> URL {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent("child2957-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func seedInOwnedProcess(_ root: URL, active: Bool, gapStage: Int = 0) async throws -> FixtureProof {
        let args = CommandLine.arguments
        let executable = URL(fileURLWithPath: args[0]).standardizedFileURL
        let childArguments: [String]
        if let flag = args.firstIndex(of: "--test-bundle-path") {
            try #require(flag + 1 < args.count)
            try #require(executable.path.hasSuffix("/usr/libexec/swift/pm/swiftpm-testing-helper"))
            childArguments = ["--test-bundle-path", args[flag + 1], "--testing-library", "swift-testing",
                "--filter", "ChildGovernorDurable2957Tests/ownedProcessFixture"]
        } else {
            let appMain = try #require(Bundle.main.executableURL).standardizedFileURL
            try #require(executable == appMain)
            try #require(executable.lastPathComponent == "MinisCanvasOriginalAppMain")
            try #require(executable.path.contains("R13OriginalAppMain.app/Contents/MacOS/"))
            childArguments = ["--testing-library", "swift-testing", "--no-parallel",
                "--filter", "ChildGovernorDurable2957Tests/ownedProcessFixture"]
        }
        let nonce = UUID().uuidString
        let request = FixtureRequest(root: root, proof: root.appendingPathComponent("fixture-proof-\(nonce).json"),
            parentPID: getpid(), nonce: nonce, active: active, gapStage: gapStage)
        let process = Process()
        process.executableURL = executable
        process.arguments = childArguments
        var environment = ProcessInfo.processInfo.environment
        environment["MINISCANVAS_CHILD2957_REQUEST"] = try JSONEncoder().encode(request).base64EncodedString()
        process.environment = environment
        let raw = root.appendingPathComponent("fixture-\(request.nonce).raw.log")
        try #require(FileManager.default.createFile(atPath: raw.path, contents: nil))
        let output = try FileHandle(forWritingTo: raw)
        process.standardOutput = output
        process.standardError = output
        defer { try? output.close() }
        try process.run()
        #expect(await wait(iterations: 3000) { !process.isRunning })
        // A stalled fixture is a test failure, never grounds for another runner.
        guard !process.isRunning else { return try #require(nil as FixtureProof?) }
        process.waitUntilExit()
        #expect(process.terminationReason == .exit && process.terminationStatus == 0)
        let proof = try JSONDecoder().decode(FixtureProof.self, from: Data(contentsOf: request.proof))
        #expect(proof.pid != getpid() && proof.pid == process.processIdentifier)
        #expect(proof.nonce == request.nonce)
        return proof
    }

    /// Subprocess fixture deliberately exits with live waiters to model loss
    /// of the old process. Its zero exit is fixture transport, not a test PASS.
    @Test func ownedProcessFixture() async throws {
        guard let encoded = ProcessInfo.processInfo.environment["MINISCANVAS_CHILD2957_REQUEST"] else { return }
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let request = try JSONDecoder().decode(FixtureRequest.self,
            from: try #require(Data(base64Encoded: encoded)))
        let root = request.root.standardizedFileURL.resolvingSymlinksInPath()
        let boundary = formal.rootDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        try #require(root.path.hasPrefix(boundary) && request.parentPID != getpid())
        let bridge = try makeBridge(root)
        let governor = try await attach(bridge, root: root)
        let revision = try #require(bridge.childGovernorControlRevision)
        if !request.active { #expect(await governor.degradeActualConcurrency(to: 0, controlRevision: revision)) }
        let calls = ChildCalls2957()
        let controllerA = TurnController()
        let controllerB = TurnController()
        let turnA = await controllerA.beginTurn()
        let turnB = await controllerB.beginTurn()
        if request.gapStage == 3 {
            let store = bridge.agentTaskStore
            let orchestrator = producer("A", bridge: bridge, governor: governor, calls: calls, handle: turnA) { _, active in
                guard active else { return }
                do {
                    let checkpoint = await governor.checkpoint()
                    let records = store.childLaunchIntents()
                    try #require(records.count == 1)
                    let record = try #require(records.first)
                    let observedCalls = await calls.observed()
                    try #require(checkpoint.globalActive == 1 && checkpoint.activeRequests.count == 1)
                    try #require(checkpoint.activeRequests.first?.intent?.intentID == record.intent.intentID)
                    try #require(record.status == .admitted && record.intent.taskID == "child-A")
                    try #require(record.intent.runID == nil && record.intent.attemptID == nil && observedCalls.isEmpty)
                    let ledger = try Data(contentsOf: root.appendingPathComponent("tasks.json"))
                    let proof = FixtureProof(pid: getpid(), nonce: request.nonce, calls: observedCalls,
                        queued: checkpoint.queuedSessions, active: checkpoint.globalActive,
                        intentIDs: [record.intent.intentID], taskLedgerDigest: DeletionGate.fingerprint(ledger))
                    try JSONEncoder().encode(proof).write(to: request.proof, options: .atomic)
                    exit(0) // The owned writer stops at the pre-start activity callback.
                } catch {
                    Issue.record("Owned admitted fixture did not reach the expected pre-start boundary")
                    exit(1)
                }
            }
            _ = await launch(orchestrator, session: "A").value
            Issue.record("Owned admitted fixture did not exit at the activity callback")
            exit(1)
        }
        if request.gapStage == 1 {
            // Hold only this owned journal lock. The real producer commits
            // its intent first, then blocks at the governor's durable write.
            let checkpoint = await governor.checkpoint()
            let lockURL = root.appendingPathComponent("sessions/child-concurrency-checkpoint-v1.json.lock")
            let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
            try #require(descriptor >= 0 && flock(descriptor, LOCK_EX) == 0)
            let b = launch(producer("B", bridge: bridge, governor: governor, calls: calls, handle: turnB), session: "B")
            try #require(await wait {
                bridge.agentTaskStore.childLaunchIntents().contains { $0.intent.recoveredFromIntentID != nil }
            })
            let committed = try #require(bridge.agentTaskStore.childLaunchIntents().last {
                $0.intent.taskID == "child-B" && $0.intent.recoveredFromIntentID != nil
            })
            let proof = FixtureProof(pid: getpid(), nonce: request.nonce, calls: await calls.observed(),
                queued: checkpoint.recoveredQueuedRequests.map(\.sessionID), active: checkpoint.globalActive,
                intentIDs: [committed.intent.intentID])
            try JSONEncoder().encode(proof).write(to: request.proof, options: .atomic)
            _ = b
            exit(0) // OS releases the owned lock; no effect was admitted.
        }
        if request.gapStage == 2 {
            let a = launch(producer("A", bridge: bridge, governor: governor, calls: calls, handle: turnA), session: "A")
            try #require(await wait {
                await governor.checkpoint().queuedSessions == ["parent-A-\(getpid())"]
            })
            let checkpoint = await governor.checkpoint()
            let committed = try #require(checkpoint.queuedRequests.first?.intent)
            let proof = FixtureProof(pid: getpid(), nonce: request.nonce, calls: await calls.observed(),
                queued: checkpoint.queuedSessions, active: checkpoint.globalActive,
                intentIDs: [committed.intentID])
            try JSONEncoder().encode(proof).write(to: request.proof, options: .atomic)
            _ = a
            exit(0) // A is requeued and B is inert; original A/B FIFO survives.
        }
        let a = launch(producer("A", bridge: bridge, governor: governor, calls: calls, handle: turnA), session: "A")
        if request.active {
            try #require(await wait { await calls.observed() == ["A"] })
        } else {
            try #require(await wait { await governor.checkpoint().queuedSessions == ["parent-A-\(getpid())"] })
        }
        let b = launch(producer("B", bridge: bridge, governor: governor, calls: calls, handle: turnB), session: "B")
        let expected = request.active ? ["parent-B-\(getpid())"] : ["parent-A-\(getpid())", "parent-B-\(getpid())"]
        try #require(await wait { await governor.checkpoint().queuedSessions == expected })
        let checkpoint = await governor.checkpoint()
        try #require(checkpoint.queuedRequests.allSatisfy { $0.intent != nil })
        let proof = FixtureProof(pid: getpid(), nonce: request.nonce, calls: await calls.observed(),
            queued: checkpoint.queuedSessions, active: checkpoint.globalActive,
            intentIDs: checkpoint.queuedRequests.compactMap { $0.intent?.intentID })
        try JSONEncoder().encode(proof).write(to: request.proof, options: .atomic)
        _ = (a, b) // Both old live tasks disappear with this owned process.
        exit(0)
    }

    @Test(arguments: [0, 1, 2])
    func productionReopenKeepsQueueAndFreshTurnResumesFairlyWithoutOldPermissions(gapStage: Int) async throws {
        let root = try makeRoot()
        let proof = try await seedInOwnedProcess(root, active: false)
        #expect(proof.calls.isEmpty && proof.active == 0)
        let gapProof: FixtureProof?
        if gapStage > 0 {
            gapProof = try await seedInOwnedProcess(root, active: false, gapStage: gapStage)
            #expect(gapProof?.calls.isEmpty == true && gapProof?.active == 0)
        } else { gapProof = nil }
        let bridge = try makeBridge(root)
        let governor = try await attach(bridge, root: root)
        try #require(await wait { bridge.pendingChildLaunchRecovery.count == 2 })
        let before = bridge.pendingChildLaunchRecovery
        #expect(before.count == 2)
        #expect(before.first?.intent?.parent.sessionID == "A")
        #expect(before.last?.intent?.parent.sessionID == "B")
        #expect(before.allSatisfy { $0.intent?.parent.taskID != "parent-\($0.intent?.parent.sessionID ?? "")-\(getpid())" })
        if let gapProof {
            let mapped = gapStage == 1 ? before.last?.intent?.intentID : before.first?.intent?.intentID
            let original = gapStage == 1 ? proof.intentIDs.last : proof.intentIDs.first
            #expect(mapped == gapProof.intentIDs.first)
            #expect(mapped != original)
        }
        #expect(bridge.recoveryNotices.contains { $0.contains("排队任务") })
        #expect(before.allSatisfy { $0.intent?.runID == nil && $0.intent?.attemptID == nil })
        #expect(await governor.checkpoint().globalActive == 0)
        #expect(await governor.checkpoint().degradedCeiling == 0)
        let calls = ChildCalls2957()
        let controllerA = TurnController(), controllerB = TurnController()
        let turnA = await controllerA.beginTurn(), turnB = await controllerB.beginTurn()
        // The actual new process may reuse the numeric turn counter; the
        // verified live handle and unique durable intent distinguish it.
        #expect(before.first?.intent?.parent.turnID == "turn-handle:\(turnA.turnID)")
        let b = launch(producer("B", bridge: bridge, governor: governor, calls: calls, handle: turnB), session: "B")
        try #require(await wait { await governor.checkpoint().queuedSessions == ["parent-B-\(getpid())"] })
        let a = launch(producer("A", bridge: bridge, governor: governor, calls: calls, handle: turnA), session: "A")
        try #require(await wait { await governor.checkpoint().queuedSessions == ["parent-A-\(getpid())", "parent-B-\(getpid())"] })
        #expect(await calls.observed().isEmpty)
        let restored = await governor.checkpoint()
        #expect(restored.recoveredQueuedRequests.isEmpty)
        #expect(restored.queuedRequests.allSatisfy { $0.intent?.recoveredFromIntentID != nil })
        #expect(restored.queuedRequests.allSatisfy { $0.intent?.intentID != $0.intent?.recoveredFromIntentID })
        let revision = try #require(bridge.childGovernorControlRevision)
        #expect(await governor.restoreActualConcurrency(controlRevision: revision))
        try #require(await wait { await calls.observed() == ["A"] })
        #expect(await governor.checkpoint().globalActive == 1)
        await calls.release("A")
        #expect(await a.value.first?.result.isSuccess == true)
        try #require(await wait { await calls.observed() == ["A", "B"] })
        #expect(await governor.checkpoint().globalActive == 1)
        await calls.release("B")
        #expect(await b.value.first?.result.isSuccess == true)
        #expect(await wait { await governor.checkpoint().globalActive == 0 })
        #expect(await governor.checkpoint().queuedRequests.isEmpty)
        let receipts = bridge.agentTaskStore.allReceipts()
        #expect(receipts.count == 2)
        for request in restored.queuedRequests {
            let intentID = try #require(request.intent?.intentID)
            let record = try #require(bridge.agentTaskStore.childLaunchIntent(intentID: intentID))
            #expect(record.intent.runID != nil && record.intent.attemptID != nil)
            #expect(receipts.contains { $0.runID == record.intent.runID && $0.attemptID == record.intent.attemptID })
        }
        #expect(bridge.childConcurrencySelection.userSelected == 1)
        await turnA.finish(); await turnB.finish()
    }

    @Test func admittedBeforeStartupReopensWithoutPartialLedgerOrReplay() async throws {
        let root = try makeRoot()
        let proof = try await seedInOwnedProcess(root, active: true, gapStage: 3)
        #expect(proof.calls.isEmpty && proof.queued.isEmpty && proof.active == 1)
        let ledgerURL = root.appendingPathComponent("tasks.json")
        let ledger = try Data(contentsOf: ledgerURL)
        let digest = try #require(proof.taskLedgerDigest)
        #expect(DeletionGate.fingerprint(ledger) == digest)
        let envelope = try #require(JSONSerialization.jsonObject(with: ledger) as? [String: Any])
        let state = try #require(envelope["state"] as? [String: Any])
        for key in ["tasks", "runs", "attempts", "taskKeyByRunID", "attemptIDByRunID", "controlByTaskKey", "events"] {
            let entries = try #require(state[key] as? [String: Any])
            #expect(entries.isEmpty, "Pre-start ledger must have no entries in \(key)")
        }

        let bridge = try makeBridge(root)
        let governor = try await attach(bridge, root: root)
        try #require(await wait { bridge.unconfirmedChildLaunchRecovery.count == 1 })
        let old = try #require(bridge.unconfirmedChildLaunchRecovery.first?.intent)
        let record = try #require(bridge.agentTaskStore.childLaunchIntent(intentID: old.intentID))
        #expect(proof.intentIDs == [old.intentID] && record.intent == old)
        #expect(record.status == .admitted && old.runID == nil && old.attemptID == nil)
        #expect(old.taskID == "child-A" && old.parent.sessionID == "A" && old.parent.actorID == "owned2957")
        #expect(bridge.agentTaskStore.childLaunchIntents() == [record])
        #expect(try Data(contentsOf: ledgerURL) == ledger)
        #expect(await governor.checkpoint().globalActive == 0)

        let calls = ChildCalls2957(), controller = TurnController()
        let turn = await controller.beginTurn()
        let reports = await launch(
            producer("A", bridge: bridge, governor: governor, calls: calls, handle: turn, timeout: 0.3),
            session: "A"
        ).value
        #expect(reports.count == 1 && reports.first?.result.error == "CHILD_CHECKPOINT_UNAVAILABLE")
        #expect(await calls.observed().isEmpty)
        #expect(bridge.agentTaskStore.childLaunchIntents() == [record])
        #expect(try Data(contentsOf: ledgerURL) == ledger)
        await turn.finish()
    }

    @Test func admittedOldCallReopensUnknownAndCannotBeResubmitted() async throws {
        let root = try makeRoot()
        let proof = try await seedInOwnedProcess(root, active: true)
        #expect(proof.calls == ["A"] && proof.active == 1)
        let bridge = try makeBridge(root)
        let governor = try await attach(bridge, root: root)
        try #require(await wait { bridge.unconfirmedChildLaunchRecovery.count == 1 })
        #expect(bridge.recoveryNotices.contains { $0.contains("结果待核对") })
        let old = try #require(bridge.unconfirmedChildLaunchRecovery.first?.intent)
        let record = try #require(bridge.agentTaskStore.childLaunchIntent(intentID: old.intentID))
        let runID = try #require(record.intent.runID)
        let attemptID = try #require(record.intent.attemptID)
        #expect(bridge.agentTaskStore.recoveryState(runID: runID) == .needsUserReview)
        #expect(bridge.agentTaskStore.attempts(runID: runID).map(\.attemptID) == [attemptID])
        let control = try #require(bridge.agentTaskStore.controlSnapshot(taskID: old.taskID, parentID: old.parent.taskID))
        #expect(control.runID == runID)
        #expect(bridge.agentTaskStore.snapshot(taskID: old.taskID, parentID: old.parent.taskID)?.taskID == old.taskID)
        #expect(bridge.agentTaskStore.events(runID: runID).filter { $0.kind == .started }.count == 1)
        #expect(await governor.checkpoint().globalActive == 0)
        let calls = ChildCalls2957(), controller = TurnController()
        let turn = await controller.beginTurn()
        let reports = await producer("A", bridge: bridge, governor: governor, calls: calls, handle: turn, timeout: 0.3)
            .orchestrate(tasks: [SubAgentTask(id: "child-A", title: "Owned A", instructions: "Complete owned A")],
                         strategy: .sequential)
        #expect(reports.first?.result.isSuccess == false)
        #expect(await calls.observed().isEmpty)
        await calls.release("A")
        #expect(bridge.agentTaskStore.allReceipts().isEmpty)
        #expect(await governor.checkpoint().globalActive == 0)
        await turn.finish()
    }

    @Test func corruptJournalAndStaleWriterRefuseActualNewProviderCalls() async throws {
        let root = try makeRoot()
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let oldJournal = try ChildGovernorCheckpointJournal2957(directory: sessions)
        let checkpoint = ChildConcurrencyCheckpoint(epoch: 1, globalActive: 0, perSessionActive: [:],
            queuedSessions: [], killSwitchEngaged: false, degradedCeiling: nil, timestamp: 1)
        try oldJournal.write(checkpoint)
        let current = try ChildGovernorCheckpointJournal2957(directory: sessions)
        try current.write(ChildConcurrencyCheckpoint(epoch: 2, globalActive: 0, perSessionActive: [:],
            queuedSessions: [], killSwitchEngaged: false, degradedCeiling: nil, timestamp: 2))
        #expect(throws: ChildGovernorCheckpointJournal2957.Failure.staleWriter) { try oldJournal.write(checkpoint) }
        try Data("corrupt-owned-journal".utf8).write(
            to: sessions.appendingPathComponent("child-concurrency-checkpoint-v1.json"), options: .atomic)
        let bridge = try makeBridge(root)
        let governor = try await attach(bridge, root: root)
        #expect(bridge.childGovernorCheckpointRecoveryUnavailable)
        let calls = ChildCalls2957(), controller = TurnController()
        let turn = await controller.beginTurn()
        let reports = await producer("A", bridge: bridge, governor: governor, calls: calls, handle: turn, timeout: 0.3)
            .orchestrate(tasks: [SubAgentTask(id: "child-A", title: "Owned A", instructions: "Complete owned A")],
                         strategy: .sequential)
        #expect(reports.first?.result.isSuccess == false)
        #expect(await calls.observed().isEmpty)
        await calls.release("A")
        #expect(try String(contentsOf: sessions.appendingPathComponent("child-concurrency-checkpoint-v1.json"),
                           encoding: .utf8) == "corrupt-owned-journal")
        #expect(await governor.checkpoint().globalActive == 0)
        await turn.finish()
    }
}
