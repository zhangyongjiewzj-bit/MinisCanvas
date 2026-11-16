import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private struct ChildNoTools2784: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String {
        throw ToolExecutorError.toolNotConfigured(name)
    }
}

private actor ChildAdmissionGate2784 {
    private var arrivals = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    private var open = false

    func enter() async {
        arrivals += 1
        if open { return }
        await withCheckedContinuation { held.append($0) }
    }

    func waitForArrival() async -> Bool {
        for _ in 0..<100 {
            if arrivals > 0 { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return arrivals > 0
    }

    func release() {
        open = true
        let pending = held
        held.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class HeldChildProvider2784: LLMProvider, @unchecked Sendable {
    var name: String { "Held child 2784" }
    var model = LLMModel(id: "held2784", displayName: "Held", provider: "synthetic")
    var capabilities: Set<ProviderCapability> { [.streaming] }
    let gate: ChildAdmissionGate2784

    init(gate: ChildAdmissionGate2784) { self.gate = gate }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        await gate.enter()
        return LLMResponse(text: "done", stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("D-CHILDD shared governor lease and recovery consumer")
@MainActor
struct ChildGovernorRecovery2784Tests {
    private func queued(_ expected: [String], on governor: ChildConcurrencyGovernor) async -> Bool {
        for _ in 0..<100 {
            if await governor.checkpoint().queuedSessions == expected { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await governor.checkpoint().queuedSessions == expected
    }

    @Test("old lease cannot release replacement; restored policy admits two real sessions fairly")
    func oldLeaseCannotReleaseReplacementAfterCheckpointRecovery() async throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "child-governor-2784", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        let root = profile.rootDirectory
        let defaults = profile.makeUserDefaults()
        let taskStore = try AgentTaskStore(
            persistenceURL: root.appendingPathComponent("tasks.json"))
        let selection = try ChildConcurrencySelection(
            userSelected: 1, recommended: 1, effective: 1, enabledSessionCount: 1
        )
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: profile.makeLogManager(),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            canvasRuntimeState: .disabled, agentTaskStore: taskStore,
            contextManifestStore: ContextManifestStore(),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            providerReadinessStore: ProviderReadinessStore(directory: profile.providerConfigurationDirectory),
            taskCenterBindingPersistenceURL: root.appendingPathComponent("bindings.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
            })
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: profile.sessionDirectory,
            enableOrchestration: true,
            childConcurrencySelection: selection
        ).value
        let governor = try #require(bridge.orchestrationChildGovernor)
        #expect(bridge.childConcurrencySelection.userSelected == 1)
        #expect(await governor.globalBudget == 1)

        let oldID = ChildLaunchRequestID(rawValue: "2784-old")
        let replacementID = ChildLaunchRequestID(rawValue: "2784-replacement")
        let foreignID = ChildLaunchRequestID(rawValue: "2784-foreign")
        guard case .admitted = await governor.requestLaunch(sessionID: "same", requestID: oldID) else {
            Issue.record("old request must obtain the original permit"); return
        }
        await governor.releaseLaunch(sessionID: "same", requestID: oldID)
        guard case .admitted = await governor.requestLaunch(sessionID: "same", requestID: replacementID) else {
            Issue.record("replacement request must obtain the returned permit"); return
        }
        let foreign = Task { await governor.requestLaunch(sessionID: "other", requestID: foreignID) }
        #expect(await queued(["other"], on: governor))

        // A delayed completion for the already-returned request is not owner
        // of the replacement permit, even though both use the same session key.
        await governor.releaseLaunch(sessionID: "same", requestID: oldID)
        let afterOldRelease = await governor.checkpoint()
        #expect(afterOldRelease.globalActive == 1)
        #expect(afterOldRelease.perSessionActive["same"] == 1)
        #expect(afterOldRelease.queuedSessions == ["other"])
        await governor.releaseLaunch(sessionID: "same", requestID: replacementID)
        guard case .admitted = await foreign.value else {
            Issue.record("actual replacement release must admit the next session"); return
        }
        await governor.releaseLaunch(sessionID: "other", requestID: foreignID)
        #expect(await governor.checkpoint().globalActive == 0)

        let controlRevision = try #require(bridge.childGovernorControlRevision)
        #expect(await governor.degradeActualConcurrency(to: 0, controlRevision: controlRevision))
        let snapshot = await governor.checkpoint()
        let checkpointURL = root.appendingPathComponent("synthetic-child-governor-checkpoint.json")
        try JSONEncoder().encode(snapshot).write(to: checkpointURL, options: .atomic)
        let persisted = try JSONDecoder().decode(
            ChildConcurrencyCheckpoint.self, from: Data(contentsOf: checkpointURL)
        )
        let fresh = ChildConcurrencyGovernor.restored(
            from: persisted, policy: .init(globalHardCeiling: 1)
        )
        #expect(await fresh.checkpoint().degradedCeiling == 0)
        #expect(await fresh.checkpoint().globalActive == 0)
        await fresh.restoreActualConcurrency()

        // Drive the actual AgentOrchestrator producer path on two distinct
        // sessions against the recovered governor, not only a state model.
        let gateA = ChildAdmissionGate2784()
        let gateB = ChildAdmissionGate2784()
        let a = AgentOrchestrator(
            provider: HeldChildProvider2784(gate: gateA),
            toolExecutor: ChildNoTools2784(), parentID: "2784-A",
            childGovernor: fresh
        )
        let b = AgentOrchestrator(
            provider: HeldChildProvider2784(gate: gateB),
            toolExecutor: ChildNoTools2784(), parentID: "2784-B",
            childGovernor: fresh
        )
        let taskA = Task {
            await a.orchestrate(tasks: [SubAgentTask(id: "a", title: "A", instructions: "A")],
                                strategy: .sequential)
        }
        #expect(await gateA.waitForArrival())
        let taskB = Task {
            await b.orchestrate(tasks: [SubAgentTask(id: "b", title: "B", instructions: "B")],
                                strategy: .sequential)
        }
        #expect(await queued(["2784-B"], on: fresh))
        #expect(await fresh.checkpoint().globalActive == 1)
        await gateA.release()
        _ = await taskA.value
        #expect(await gateB.waitForArrival())
        #expect(await fresh.checkpoint().globalActive == 1)
        await gateB.release()
        _ = await taskB.value
        #expect(await fresh.checkpoint().globalActive == 0)
        #expect(await fresh.checkpoint().queuedSessions.isEmpty)
        #expect(bridge.childConcurrencySelection.userSelected == 1)
    }
}
