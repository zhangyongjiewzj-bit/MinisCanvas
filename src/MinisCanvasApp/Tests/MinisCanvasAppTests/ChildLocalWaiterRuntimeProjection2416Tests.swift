import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private struct Child2416NoTools: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String {
        throw ToolExecutorError.toolNotConfigured(name)
    }
}

private final class Child2416Provider: LLMProvider, @unchecked Sendable {
    let name = "owned2416"
    var model = LLMModel(id: "owned2416", displayName: "Owned", provider: "synthetic")
    var capabilities: Set<ProviderCapability> { [.streaming] }
    private let lock = NSLock()
    private var calls = 0
    private var active = 0
    private var released = false
    private var held: CheckedContinuation<Void, Never>?
    var callCount: Int { lock.withLock { calls } }
    var activeCount: Int { lock.withLock { active } }
    func releaseFirst() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            let result = held; held = nil
            return result
        }
        pending?.resume()
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        let first = lock.withLock { calls += 1; active += 1; return calls == 1 }
        defer { lock.withLock { active -= 1 } }
        if first {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    if released { continuation.resume() } else { held = continuation }
                }
            }
        }
        return LLMResponse(text: "owned completion", stopReason: "stop", usage: nil)
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

/// The real production Orchestrator and Bridge reporter share one governor. A local waiter
/// is distinct from an actually entered provider; no transport/server terminal
/// or new resource policy is inferred from this observation.
@Suite("CHILDB local child waiter versus live runtime projection", .serialized)
@MainActor
struct ChildLocalWaiterRuntimeProjection2416Tests {
    @Test(arguments: [false, true])
    func realLocalWaiterIsShownAsQueuedRatherThanAnotherRunningChild(cancelLocalWaiter: Bool) async throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "child-local-waiter2416", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        let defaults = profile.makeUserDefaults()
        let store = try AgentTaskStore(persistenceURL: profile.rootDirectory.appendingPathComponent("tasks.json"))
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: profile.makeLogManager(),
            workflowStore: WorkflowStore(storeDirectory: profile.rootDirectory.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            canvasRuntimeState: .disabled, agentTaskStore: store,
            contextManifestStore: ContextManifestStore(),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            providerReadinessStore: ProviderReadinessStore(directory: profile.providerConfigurationDirectory),
            taskCenterBindingPersistenceURL: profile.rootDirectory.appendingPathComponent("bindings.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
            })
        let selection = try ChildConcurrencySelection(userSelected: 1, recommended: 1,
            effective: 1, enabledSessionCount: 2)
        await bridge.attachProductionServices(fileAccessAllowedRoot: profile.rootDirectory,
            sessionDirectory: profile.sessionDirectory, enableOrchestration: true,
            childConcurrencySelection: selection).value
        let governor = try #require(bridge.orchestrationChildGovernor)
        #expect(await governor.globalBudget == 2)
        let provider = Child2416Provider()
        let controller = TurnController()
        let turn = await controller.beginTurn()
        defer { provider.releaseFirst(); Task { await turn.finish() } }
        let parent = ParentRuntimeIdentity(sessionID: "2416-A", conversationID: "2416-A",
            turnID: "turn-handle:\(turn.turnID)", taskID: "2416-A", actorID: "owned2416")
        // Use the Bridge-owned canonical Store and retained global actor. The
        // production Orchestrator owns the actual per-orchestration gate;
        // this test never requests a synthetic permit from the governor.
        let orchestrator = AgentOrchestrator(childConcurrencySelection: selection,
            provider: provider, toolExecutor: Child2416NoTools(), childTimeout: 10,
            currentConversationID: parent.sessionID, taskStore: store, parentID: parent.taskID,
            parentBinding: ParentContextSnapshotV1(providerID: provider.name, modelID: provider.model.id,
                configurationFingerprint: "2416-frozen", conversationID: parent.conversationID),
            parentRuntimeIdentity: parent,
            parentGoal: GoalEnvelope(scopeID: "2416-scope", allowedCapabilities: ["orchestrate"],
                budget: 100, deadline: Date().addingTimeInterval(30), autonomyLevel: .l3),
            parentTurnHandle: turn, runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.streaming]),
            parentCapabilities: [.streaming], childGovernor: governor)
        let work = Task {
            await orchestrator.orchestrate(tasks: [
                SubAgentTask(id: "2416-A1", title: "First", instructions: "Owned hold", requiredCapabilities: [.streaming]),
                SubAgentTask(id: "2416-A2", title: "Second", instructions: "Owned reply", requiredCapabilities: [.streaming])
            ], strategy: .parallelWithLimit(limit: 1))
        }
        defer { work.cancel() }
        let limit = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < limit {
            if await governor.currentGlobalActive == 2 && provider.callCount == 1,
               let report = bridge.childConcurrencySelection.runtime,
               report.actualRunning > 0 && report.actualRunning + report.queued == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(provider.callCount == 1 && provider.activeCount == 1,
                     "first real provider must be held and the second must wait at the local gate")
        let report = try #require(bridge.childConcurrencySelection.runtime)
        print("TASK2416 actualProvider=\(provider.activeCount) calls=\(provider.callCount) actualDisplay=\(report.actualRunning) queuedDisplay=\(report.queued)")
        #expect(bridge.childConcurrencySelection.userSelected == 1)
        #expect(bridge.childConcurrencySelection.effective == 1)
        #expect(bridge.childConcurrencySelection.sideBySideProjection.count == 5)
        #expect(report.actualRunning == 1)
        #expect(report.queued == 1)
        if cancelLocalWaiter {
            // Cancellation abandons the local waiter, while the already-entered
            // uncooperative provider keeps the original global permit alive.
            await turn.revoke()
            let cancelled = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < cancelled {
                let checkpoint = await governor.checkpoint()
                if checkpoint.globalActive == 1 && checkpoint.localWaitingRequests == 0,
                   bridge.childConcurrencySelection.runtime?.actualRunning == 1,
                   bridge.childConcurrencySelection.runtime?.queued == 0 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(provider.callCount == 1 && provider.activeCount == 1)
            #expect(await governor.checkpoint().globalActive == 1)
            #expect(await governor.checkpoint().localWaitingRequests == 0)
            #expect(bridge.childConcurrencySelection.runtime?.actualRunning == 1)
            #expect(bridge.childConcurrencySelection.runtime?.queued == 0)
        }
        provider.releaseFirst()
        let reports = await work.value
        #expect(reports.count == 2)
        #expect(reports.allSatisfy { $0.result.isSuccess != cancelLocalWaiter })
        #expect(provider.callCount == (cancelLocalWaiter ? 1 : 2))
        // Outward cancellation can settle before the ignoring-cancellation
        // provider returns. Resuming its continuation is not an exit receipt;
        // observe actual exit and the retained global permit before asserting
        // that the final Bridge projection is idle.
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < end {
            if provider.activeCount == 0, await governor.currentGlobalActive == 0,
               bridge.childConcurrencySelection.runtime?.actualRunning == 0,
               bridge.childConcurrencySelection.runtime?.queued == 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let exitedProviderCount = provider.activeCount
        let finalCheckpoint = await governor.checkpoint()
        print("TASK2538 actualProvider=\(exitedProviderCount) calls=\(provider.callCount) global=\(finalCheckpoint.globalActive) queued=\(finalCheckpoint.queuedSessions.count) localWaiting=\(finalCheckpoint.localWaitingRequests)")
        #expect(exitedProviderCount == 0, "controlled provider did not exit within the bounded five-second drain")
        #expect(finalCheckpoint.globalActive == 0, "actual operation still retains its permit after the bounded drain")
        #expect(finalCheckpoint.queuedSessions.isEmpty)
        #expect(finalCheckpoint.localWaitingRequests == 0)
        #expect(bridge.childConcurrencySelection.runtime?.actualRunning == 0)
        #expect(bridge.childConcurrencySelection.runtime?.queued == 0)
    }

    @Test
    func oldCheckpointAndNewLocalReservationBothRestoreOnlyPolicy() async throws {
        let legacy = Data(#"{"epoch":8,"globalActive":2,"perSessionActive":{"owned":2},"queuedSessions":["queued"],"killSwitchEngaged":true,"timestamp":123}"#.utf8)
        let old = try JSONDecoder().decode(ChildConcurrencyCheckpoint.self, from: legacy)
        #expect(old.localWaitingRequests == 0)
        let reserved = ChildConcurrencyCheckpoint(epoch: old.epoch,
            globalActive: old.globalActive, perSessionActive: old.perSessionActive,
            queuedSessions: old.queuedSessions, killSwitchEngaged: old.killSwitchEngaged,
            degradedCeiling: old.degradedCeiling, timestamp: old.timestamp,
            localWaitingRequests: 1)
        let reopened = try JSONDecoder().decode(ChildConcurrencyCheckpoint.self,
            from: JSONEncoder().encode(reserved))
        #expect(reopened == reserved)
        for snapshot in [old, reopened] {
            let restored = ChildConcurrencyGovernor.restored(from: snapshot,
                policy: .init(globalHardCeiling: 2))
            let current = await restored.checkpoint()
            #expect(current.globalActive == 0 && current.localWaitingRequests == 0)
            #expect(current.queuedSessions.isEmpty && current.perSessionActive.isEmpty)
            #expect(current.killSwitchEngaged && current.epoch == 8)
            if case .blockedByKillSwitch = await restored.requestLaunch(sessionID: "owned-new") { }
            else { Issue.record("restored stop-new-launch policy must remain authoritative") }
        }
    }
}
