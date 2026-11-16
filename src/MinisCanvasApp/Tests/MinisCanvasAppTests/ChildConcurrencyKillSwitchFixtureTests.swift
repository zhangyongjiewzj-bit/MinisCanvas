import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("CHILD-40 Kill Switch drain")
@MainActor
struct ChildConcurrencyKillSwitchFixtureTests {
    @Test("Kill Switch settles queued and running children without rewriting selection")
    func killSwitchDrainsChildWorkWithoutRewritingSelection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Child40KillSwitch-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10)
        )
        center.childConcurrencyUserSelected = 40
        center.childConcurrencyRiskAcknowledged = true
        let selected = center.childConcurrencySelection

        let store = AgentTaskStore()
        let parent = try store.enqueue(
            taskID: "child40-parent",
            parentID: "root",
            providerID: "offline",
            modelID: "test"
        )
        let queued = try store.enqueue(
            taskID: "child40-queued",
            parentID: parent.taskID,
            providerID: "offline",
            modelID: "test"
        )
        let running = try store.enqueue(
            taskID: "child40-running",
            parentID: parent.taskID,
            providerID: "offline",
            modelID: "test"
        )
        let runningRun = try store.startRun(
            taskID: running.taskID,
            parentID: parent.taskID,
            runID: "child40-running-run"
        )

        let bridge = BridgeStore(agentTaskStore: store)
        bridge.attachProductionServices(
            sessionDirectory: directory,
            enableOrchestration: true,
            childConcurrencySelection: selected
        )
        let projection = bridge.taskCenterGoalProjection()
        let fact = try #require(
            projection.fact(taskID: parent.taskID, parentID: parent.parentID)
        )
        let stopRequest = TaskCenterControlRequest(
            taskID: fact.taskID,
            parentID: fact.parentID,
            revision: fact.revision,
            scopeID: fact.scopeID ?? "",
            actorID: "kill-switch-fixture",
            idempotencyKey: "child40-kill-switch-stop",
            action: .stop
        )

        center.engageKillSwitch()
        let safetyTransition = bridge.updateSafetyRuntimeSnapshot(
            center.safetyRuntimeSnapshot
        )
        let settled = try bridge.executeTaskCenterControl(stopRequest)

        #expect(safetyTransition.generation == 1)
        #expect(!bridge.orchestrationEnabled)
        #expect(bridge.childConcurrencySelection == selected)
        #expect(
            Set(settled.cancelledTaskIDs)
                == Set([parent.taskID, queued.taskID, running.taskID])
        )
        #expect(
            store.snapshot(taskID: parent.taskID, parentID: parent.parentID)?.status
                == .cancelled
        )
        #expect(
            store.snapshot(taskID: queued.taskID, parentID: parent.taskID)?.status
                == .cancelled
        )
        #expect(
            store.snapshot(taskID: running.taskID, parentID: parent.taskID)?.status
                == .cancelled
        )
        #expect(
            store.events(runID: runningRun.runID).map(\.kind) == [.cancelled]
        )

        let restarted = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10)
        )
        #expect(restarted.childConcurrencyUserSelected == 40)
        #expect(restarted.childConcurrencyEffective == 4)
        #expect(restarted.killSwitchEnabled)
    }
}
