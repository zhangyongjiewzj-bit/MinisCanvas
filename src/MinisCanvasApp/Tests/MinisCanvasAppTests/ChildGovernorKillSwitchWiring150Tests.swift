import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// P3-CHILD-40 (lane 150): the shipped app's single safety/Kill-Switch owner
// (SettingsCenter) now reaches the ONE cross-session child governor through
// BridgeStore's existing `updateSafetyRuntimeSnapshot` observation seam and the
// existing safety-lock engage transition. These tests drive the governor ONLY
// through real app-safety state (never by calling `engageKillSwitch()` on the
// governor directly — that is exactly the dead-code path lane 142 left behind),
// and pin that:
//   * engaging the app Kill Switch makes the governor refuse new launches
//     (`.blockedByKillSwitch`, fail-closed) on the SAME shared instance,
//   * lifting it resumes admission,
//   * the engage transition drives `governor.checkpoint()` at a real runtime
//     transition that already exists,
//   * a Kill Switch already engaged before orchestration is attached is
//     reconciled at attach so a persisted-kill boot fails closed immediately.
//
// These files were authored under a "do not build / do not run" constraint:
// nothing here was compiled or executed; PKG_MAIN owns the single heavy gate.
@Suite("P3-CHILD-40 app Kill Switch drives the shared child governor (lane 150)")
@MainActor
struct ChildGovernorKillSwitchWiring150Tests {

    private actor DecisionBox {
        var decision: ChildConcurrencyDecision?
        func record(_ value: ChildConcurrencyDecision) { decision = value }
    }

    private func makeSettings(_ profile: RuntimeIsolationProfile) -> SettingsCenter {
        SettingsCenter(
            settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: EnvVarStore(directory: profile.minisCoreDirectory),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            logManager: LogManager(directory: profile.logDirectory, ringCapacity: 10)
        )
    }

    private func findPolicy(_ executor: any ToolExecutor) -> PolicyEnforcedToolExecutor? {
        if let policy = executor as? PolicyEnforcedToolExecutor { return policy }
        if let recording = executor as? RecordingToolExecutor {
            return findPolicy(recording.base)
        }
        if let limiting = executor as? ConcurrentToolLimitingExecutor {
            return findPolicy(limiting.baseBox.value)
        }
        return nil
    }

    private func waitUntilQueued(
        _ sessionID: String, on governor: ChildConcurrencyGovernor
    ) async -> Bool {
        for _ in 0..<100 {
            if await governor.checkpoint().queuedSessions.contains(sessionID) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await governor.checkpoint().queuedSessions.contains(sessionID)
    }

    private func waitForDecision(_ box: DecisionBox) async -> ChildConcurrencyDecision? {
        for _ in 0..<100 {
            if let decision = await box.decision { return decision }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await box.decision
    }

    private func makeAttachedBridge(
        _ tag: String
    ) throws -> (BridgeStore, ChildConcurrencyGovernor, URL) {
        let bridge = BridgeStore()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-child40-ks150-\(tag)-\(UUID().uuidString)")
        bridge.attachProductionServices(sessionDirectory: dir, enableOrchestration: true)
        let governor = try #require(bridge.orchestrationChildGovernor)
        return (bridge, governor, dir)
    }

    /// (1) Engaging the APP Kill Switch (not the governor API directly) drives
    /// the ONE shared governor into fail-closed: a subsequent cross-session
    /// launch request returns `.blockedByKillSwitch`. Also pins that the wiring
    /// reconciles the SAME instance — no second governor is introduced.
    @Test("app Kill Switch engages the shared governor and blocks new launches")
    func appKillSwitchEngagesSharedGovernorFailClosed() async throws {
        let (bridge, governor, dir) = try makeAttachedBridge("engage")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Baseline: a freshly attached governor is not engaged.
        #expect(await governor.isKillSwitchEngaged == false)
        let physicalBeforeLock = await governor.checkpoint()

        // Drive the safety state exactly as SettingsCenter does.
        bridge.updateSafetyRuntimeSnapshot(
            SafetyControlState(safeModeEnabled: false, killSwitchEnabled: true)
        )
        // Await the reconcile task the observation seam scheduled.
        await bridge.lastChildGovernorSafetyTask?.value

        #expect(await governor.isKillSwitchEngaged == true)
        // Disabled assembly exposes no optional executable governor, while the
        // original physical handle still owns its exact resource account.
        #expect(bridge.orchestrationChildGovernor == nil)
        #expect(!bridge.orchestrationEnabled)
        let physicalWhileLocked = await governor.checkpoint()
        #expect(physicalWhileLocked.globalActive == physicalBeforeLock.globalActive)
        #expect(physicalWhileLocked.perSessionActive == physicalBeforeLock.perSessionActive)
        #expect(physicalWhileLocked.queuedSessions == physicalBeforeLock.queuedSessions)

        // Negative control (fail-closed): a NEW launch request is refused.
        let decision = await governor.requestLaunch(
            sessionID: "child40-ks150-engage",
            requestID: ChildLaunchRequestID(rawValue: "child40-ks150-engage-req")
        )
        guard case .blockedByKillSwitch = decision else {
            Issue.record("engaged governor must refuse new launches, got \(decision)")
            return
        }
        // No slot was handed out while the Kill Switch is engaged.
        #expect(await governor.currentGlobalActive == 0)
        bridge.updateSafetyRuntimeSnapshot(
            SafetyControlState(safeModeEnabled: false, killSwitchEnabled: false)
        )
        await bridge.lastChildGovernorSafetyTask?.value
        #expect(bridge.orchestrationChildGovernor === governor)
        #expect(bridge.orchestrationEnabled)
        #expect(await governor.isKillSwitchEngaged == false)
        #expect(await governor.currentGlobalActive == physicalBeforeLock.globalActive)
    }

    /// (2) Lifting the APP Kill Switch resumes the governor: after re-clearing
    /// safety state the next request is admitted again (the engage half alone
    /// would not distinguish a stuck governor).
    @Test("lifting the app Kill Switch resumes governor admission")
    func appKillSwitchLiftResumesGovernor() async throws {
        let (bridge, governor, dir) = try makeAttachedBridge("lift")
        defer { try? FileManager.default.removeItem(at: dir) }

        bridge.updateSafetyRuntimeSnapshot(
            SafetyControlState(safeModeEnabled: false, killSwitchEnabled: true)
        )
        await bridge.lastChildGovernorSafetyTask?.value
        #expect(await governor.isKillSwitchEngaged == true)

        bridge.updateSafetyRuntimeSnapshot(
            SafetyControlState(safeModeEnabled: false, killSwitchEnabled: false)
        )
        await bridge.lastChildGovernorSafetyTask?.value
        #expect(await governor.isKillSwitchEngaged == false)

        let decision = await governor.requestLaunch(
            sessionID: "child40-ks150-lift",
            requestID: ChildLaunchRequestID(rawValue: "child40-ks150-lift-req")
        )
        guard case .admitted = decision else {
            Issue.record("lifted governor must admit a launch, got \(decision)")
            return
        }
        await governor.releaseLaunch(sessionID: "child40-ks150-lift")
    }

    /// (3) The safety-lock engage transition (which already bumps
    /// `safetyRuntimeCheckpointRequests` and cancels optional work) now also
    /// drives `governor.checkpoint()`. Nothing else in production writes that
    /// snapshot, so a non-nil result proves `checkpoint()` is reached from the
    /// real transition, not merely from a test calling it.
    @Test("engaging the app Kill Switch checkpoints the shared governor")
    func appKillSwitchEngageCapturesGovernorCheckpoint() async throws {
        let (bridge, governor, dir) = try makeAttachedBridge("checkpoint")
        defer { try? FileManager.default.removeItem(at: dir) }

        let epochBefore = await governor.checkpoint().epoch
        #expect(bridge.lastChildGovernorCheckpoint == nil)

        bridge.updateSafetyRuntimeSnapshot(
            SafetyControlState(safeModeEnabled: false, killSwitchEnabled: true)
        )
        await bridge.lastChildGovernorCheckpointTask?.value

        let captured = try #require(bridge.lastChildGovernorCheckpoint)
        // The captured snapshot belongs to the ONE shared governor (matching
        // monotonic epoch) and is retained for audit only (degrade never wired).
        #expect(captured.epoch >= epochBefore)
        #expect(captured.degradedCeiling == nil)
    }

    /// A persisted Kill Switch disables optional orchestration at composition;
    /// no governor or runner may be created while the lock is active.
    @Test("persisted Kill Switch boot does not compose orchestration")
    func persistedKillBootStaysUncomposed() async throws {
        let bridge = BridgeStore()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-child40-ks150-boot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Safety state applied BEFORE orchestration exists (governor is nil).
        bridge.updateSafetyRuntimeSnapshot(
            SafetyControlState(safeModeEnabled: false, killSwitchEnabled: true)
        )
        await bridge.lastChildGovernorSafetyTask?.value
        #expect(bridge.orchestrationChildGovernor == nil)

        // A disabled optional feature is absent, not a runnable governor with
        // an independent second Kill Switch state.
        bridge.attachProductionServices(sessionDirectory: dir, enableOrchestration: true)
        #expect(bridge.orchestrationChildGovernor == nil)
        #expect(bridge.orchestrationEnabled == false)
        #expect(bridge.productionExternalRunnerNames.isEmpty)
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let policy = try #require(findPolicy(engine.composedExecutor))
        #expect(!policy.goal.allowedCapabilities.contains(OrchestrationToolExecutor.toolName))
    }

    @Test("persisted Kill boot resumes only after the SettingsCenter unlock callback")
    func persistedKillBootResumesFromCurrentSettings() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "child40-kill-boot")
        defer { try? FileManager.default.removeItem(at: profile.rootDirectory) }
        makeSettings(profile).engageKillSwitch()
        let settings = makeSettings(profile) // real persisted-state reload
        #expect(settings.killSwitchEnabled)
        let bridge = BridgeStore()
        ProductionOrchestrationDefaults.bindSafetyRuntimeSnapshot(
            to: bridge, settings: settings, profile: profile
        )
        bridge.updateSafetyRuntimeSnapshot(settings.safetyRuntimeSnapshot)
        ProductionOrchestrationDefaults.attachCurrentProductionConfiguration(
            to: bridge, settings: settings, profile: profile,
            childConcurrencySelection: settings.childConcurrencySelection
        )
        #expect(bridge.orchestrationChildGovernor == nil)
        #expect(!bridge.orchestrationEnabled)
        let lockedOwner = try #require(bridge.productionBuiltinToolExecutor)

        // Neither child-selection nor approval callbacks are bound here. The
        // safety-lift reattach must consume current settings on its own, not an
        // old grant or an unrelated settings-triggered reattachment.
        settings.childConcurrencyUserSelected = 2
        settings.approvalPolicy = .deny
        #expect(bridge.orchestrationChildGovernor == nil)
        settings.disengageKillSwitch() // no child-selection or file callback
        await bridge.lastChildGovernorSafetyTask?.value
        let governor = try #require(bridge.orchestrationChildGovernor)
        #expect(bridge.orchestrationEnabled)
        #expect(bridge.productionBuiltinToolExecutor !== lockedOwner)
        #expect(await governor.isKillSwitchEngaged == false)
        #expect(bridge.childConcurrencySelection.userSelected == 2)
        #expect(await governor.globalBudget == settings.childConcurrencySelection.globalRequestedCapacity)
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.loop.approvalGate?.policy(for: OrchestrationToolExecutor.toolName) == .deny)
        let decision = await governor.requestLaunch(sessionID: "child40-after-unlock")
        guard case .admitted = decision else {
            Issue.record("current settings should admit a fresh child, got \(decision)")
            return
        }
        await governor.releaseLaunch(sessionID: "child40-after-unlock")
    }

    @Test("lifting Kill does not bypass a still-engaged Safe Mode")
    func safeModeStillBlocksRecovery() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "child40-kill-safemode")
        defer { try? FileManager.default.removeItem(at: profile.rootDirectory) }
        let settings = makeSettings(profile)
        settings.enableSafeMode()
        settings.engageKillSwitch()
        let bridge = BridgeStore()
        ProductionOrchestrationDefaults.bindSafetyRuntimeSnapshot(
            to: bridge, settings: settings, profile: profile
        )
        bridge.updateSafetyRuntimeSnapshot(settings.safetyRuntimeSnapshot)
        ProductionOrchestrationDefaults.attachCurrentProductionConfiguration(
            to: bridge, settings: settings, profile: profile,
            childConcurrencySelection: settings.childConcurrencySelection
        )
        let lockedOwner = bridge.productionBuiltinToolExecutor
        settings.disengageKillSwitch()
        #expect(bridge.safetyRuntimeSnapshot.safeModeEnabled)
        #expect(!bridge.isSafetyFeatureEnabled(.externalAgents))
        #expect(!bridge.isSafetyFeatureEnabled(.childOrchestration))
        #expect(bridge.orchestrationChildGovernor == nil)
        #expect(!bridge.orchestrationEnabled)
        #expect(bridge.productionBuiltinToolExecutor === lockedOwner)
    }

    @Test("safety lift retains the healthy governor but fences queued and old executor work")
    func safetyLiftKeepsGovernorAndRejectsOldWork() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "child40-kill-live")
        defer { try? FileManager.default.removeItem(at: profile.rootDirectory) }
        let settings = makeSettings(profile)
        settings.childConcurrencyUserSelected = 1
        let bridge = BridgeStore()
        ProductionOrchestrationDefaults.bindSafetyRuntimeSnapshot(
            to: bridge, settings: settings, profile: profile
        )
        ProductionOrchestrationDefaults.attachCurrentProductionConfiguration(
            to: bridge, settings: settings, profile: profile,
            childConcurrencySelection: settings.childConcurrencySelection
        )
        let governor = try #require(bridge.orchestrationChildGovernor)
        let oldEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let oldPolicy = try #require(findPolicy(oldEngine.composedExecutor))
        let oldSafetyGate = oldPolicy.base
        let holder = await governor.requestLaunch(sessionID: "child40-holder")
        guard case .admitted = holder else {
            Issue.record("fixture holder was not admitted: \(holder)")
            return
        }
        let waitingID = ChildLaunchRequestID(rawValue: "child40-old-queued-request")
        let decisionBox = DecisionBox()
        let waiter = Task {
            let decision = await governor.requestLaunch(
                sessionID: "child40-old-queued", requestID: waitingID
            )
            await decisionBox.record(decision)
        }
        guard await waitUntilQueued("child40-old-queued", on: governor) else {
            await governor.abandonWaiting(requestID: waitingID)
            waiter.cancel()
            Issue.record("fixture waiter did not enter the bounded queue")
            return
        }

        let preLockEpoch = bridge.safetyRuntimeGeneration
        settings.engageKillSwitch()
        await bridge.lastChildGovernorSafetyTask?.value
        #expect(bridge.safetyRuntimeGeneration > preLockEpoch)
        guard await governor.isKillSwitchEngaged else {
            await governor.abandonWaiting(requestID: waitingID)
            waiter.cancel()
            Issue.record("app Kill Switch did not engage the shared governor")
            return
        }
        // Chat stays available through the actual current locked assembly.
        // An unknown Chat tool must reach the exact base error.
        let lockedEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let lockedPolicy = try #require(findPolicy(lockedEngine.composedExecutor))
        do {
            _ = try await lockedPolicy.base.execute(
                name: "child40-unregistered-chat-tool", input: [:]
            )
            Issue.record("unknown Chat tool unexpectedly executed")
        } catch let error as ToolExecutorError {
            #expect(error == .unknownTool("child40-unregistered-chat-tool"))
        } catch {
            Issue.record("current Chat chain failed before its base error: \(error)")
        }
        // The captured pre-lock wrapper must remain fenced after reattachment,
        // including Chat tools; it is not the current available Chat chain.
        do {
            _ = try await oldSafetyGate.execute(
                name: "child40-unregistered-chat-tool", input: [:]
            )
            Issue.record("old Chat executor crossed the reattach boundary")
        } catch let error as SafetyRuntimeAdmissionError {
            #expect(error == .staleRuntime(.chat))
        } catch {
            Issue.record("old Chat executor rejected for a different reason: \(error)")
        }
        guard let oldDecision = await waitForDecision(decisionBox) else {
            await governor.abandonWaiting(requestID: waitingID)
            waiter.cancel()
            Issue.record("Kill Switch did not release queued pre-lock work within the bound")
            return
        }
        guard case .blockedByKillSwitch = oldDecision else {
            Issue.record("queued pre-lock work was not rejected: \(oldDecision)")
            return
        }
        settings.disengageKillSwitch()
        await bridge.lastChildGovernorSafetyTask?.value
        #expect(bridge.orchestrationChildGovernor === governor)
        #expect(bridge.orchestrationEnabled)
        #expect(await governor.checkpoint().queuedSessions.isEmpty)
        let newEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let newPolicy = try #require(findPolicy(newEngine.composedExecutor))
        #expect(newPolicy.goal.goalID != oldPolicy.goal.goalID)
        #expect(newPolicy.goal.allowedCapabilities.contains(OrchestrationToolExecutor.toolName))
        do {
            _ = try await newPolicy.base.execute(
                name: OrchestrationToolExecutor.toolName, input: [:]
            )
            Issue.record("empty orchestration request unexpectedly executed")
        } catch let error as ToolExecutorError {
            #expect(error == .missingParameter("input_version"))
        } catch {
            Issue.record("new chain did not reach orchestration validation: \(error)")
        }
        do {
            _ = try await oldSafetyGate.execute(
                name: OrchestrationToolExecutor.toolName, input: [:]
            )
            Issue.record("old optional executor crossed the reattach boundary")
        } catch let error as SafetyRuntimeAdmissionError {
            #expect(error == .staleRuntime(.childOrchestration))
        } catch {
            Issue.record("old executor rejected for a different reason: \(error)")
        }
        await governor.releaseLaunch(sessionID: "child40-holder")
        let fresh = await governor.requestLaunch(sessionID: "child40-fresh")
        guard case .admitted = fresh else {
            Issue.record("fresh work did not use the retained governor: \(fresh)")
            return
        }
        await governor.releaseLaunch(sessionID: "child40-fresh")
    }
}
