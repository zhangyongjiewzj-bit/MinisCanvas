import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Exercise the actual Bridge producer, rather than recreating its fingerprint
/// in a projection fixture. No UI, Provider request, or OS action is invoked.
@Suite("D-TASK-11 actual session controls remain diagnostic (681)")
@MainActor
struct TaskCenterSessionAction681ConsumerTests {
    @Test func bridgeSessionActionsRemainCanonicalButNeverEnterTheMainList() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("task681-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let domain = "task681." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        let ledgerURL = root.appendingPathComponent("agent-tasks.json")
        let tasks = try AgentTaskStore(persistenceURL: ledgerURL)
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            canvasRuntimeState: .disabled, agentTaskStore: tasks,
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            taskCenterBindingPersistenceURL: root.appendingPathComponent("bindings.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
            }
        )
        #expect(bridge.canvasIfAvailable == nil)
        #expect(bridge.chat.attachPersistence(sessions, badgeStore: badges))
        #expect(bridge.chat.sessionManager?.store === sessions)
        #expect(bridge.chat.sessionManager?.badgeStore === badges)
        let first = try #require(bridge.chat.activeSessionID)
        bridge.chat.appendUser("TASK681_OWNED_SOURCE")
        let created = try bridge.performSessionAction(.new(title: "TASK681_OWNED_NEW"))
        let second = try #require(bridge.chat.activeSessionID)
        #expect(second != first)
        let renamed = try bridge.performSessionAction(.rename(sessionID: second.uuidString, title: "TASK681_OWNED_RENAMED"))
        let switched = try bridge.performSessionAction(.switch(sessionID: first.uuidString))
        #expect(bridge.chat.activeSessionID == first)
        let forked = try bridge.performSessionAction(.fork(sessionID: first.uuidString))
        let child = try #require(bridge.chat.activeSessionID)
        #expect(child != first && child != second)
        let actions = [created, renamed, switched, forked]
        #expect(actions.map(\.receipt.action) == [.new, .rename, .switch, .fork])
        let controlIDs = Set(actions.map(\.taskID))
        #expect(controlIDs.count == 4)
        for action in actions {
            let task = try #require(tasks.snapshot(taskID: action.taskID, parentID: action.source.sessionID))
            #expect(task.configurationFingerprint == "session-action-v1")
            #expect(task.status == .succeeded && task.providerID == nil && task.modelID == nil)
            #expect(tasks.receipt(runID: action.runID)?.outcome == .succeeded)
            // AgentTaskStore intentionally discards caller detail, retaining the
            // bounded category. Provenance is the producer fingerprint above.
            #expect(tasks.events(runID: action.runID).contains {
                $0.kind == .started && $0.detail == "started"
                    && $0.runID == action.runID
                    && $0.parentContextSnapshotID == task.parentContextSnapshotID
            })
            #expect(bridge.taskCenterObservation.taskSnapshots.contains { $0.taskID == action.taskID })
        }
        let consumer = bridge.taskCenterControlConsumer
        #expect(consumer.receiptRows(includeArchived: true).isEmpty)
        #expect(consumer.userTaskObservation().counts.total == 0)
        #expect(Set(consumer.sessionActionDiagnosticObservation().taskSnapshots.map(\.taskID)) == controlIDs)
        #expect(consumer.sessionActionDiagnosticObservation().counts.succeeded == 4)
        let controlSlash = try #require(JSONSerialization.jsonObject(
            with: Data(bridge.taskCenterSlashCommandAdapter.execute("/tasks").utf8)
        ) as? [String: Any])
        let controlPayload = try #require(controlSlash["payload"] as? [String: Any])
        #expect(controlPayload["total_tasks"] as? Int == 0)
        #expect((controlPayload["tasks"] as? [[String: Any]])?.isEmpty == true)
        let controlStatus = try #require(JSONSerialization.jsonObject(
            with: Data(bridge.taskCenterSlashCommandAdapter.execute("/status").utf8)
        ) as? [String: Any])
        let controlStatusPayload = try #require(controlStatus["payload"] as? [String: Any])
        #expect(controlStatusPayload["total_tasks"] as? Int == 0)

        // An ordinary task with the same spelling is a positive control: the
        // main list must depend on production provenance, not a broad prefix.
        let ordinary = try tasks.enqueue(taskID: "session-action:ordinary681", parentID: first.uuidString,
                                         providerID: "offline", modelID: "synthetic", configurationFingerprint: "ordinary681")
        let activeSession = bridge.chat.activeSessionID
        let messages = bridge.chat.messages
        let canonicalBefore = tasks.taskCenterSnapshots(includeArchived: true)
        let receiptsBefore = tasks.allReceipts()
        let bytesBefore = try Data(contentsOf: ledgerURL)
        #expect(consumer.receiptRows(includeArchived: true).map(\.taskID) == [ordinary.taskID])
        #expect(consumer.userTaskObservation().counts.total == 1)
        let ordinarySlash = try #require(JSONSerialization.jsonObject(
            with: Data(bridge.taskCenterSlashCommandAdapter.execute("/tasks").utf8)
        ) as? [String: Any])
        let ordinaryPayload = try #require(ordinarySlash["payload"] as? [String: Any])
        #expect(ordinaryPayload["total_tasks"] as? Int == 1)
        #expect((ordinaryPayload["tasks"] as? [[String: Any]])?.compactMap {
            $0["task_id"] as? String
        } == [ordinary.taskID])
        let ordinaryStatus = try #require(JSONSerialization.jsonObject(
            with: Data(bridge.taskCenterSlashCommandAdapter.execute("/status").utf8)
        ) as? [String: Any])
        let ordinaryStatusPayload = try #require(ordinaryStatus["payload"] as? [String: Any])
        #expect(ordinaryStatusPayload["total_tasks"] as? Int == 1)
        #expect(consumer.homeReceiptSections(TaskCenterReceiptFilter()).current.map(\.taskID) == [ordinary.taskID])
        for status in TaskCenterFilterStatus.allCases {
            #expect(consumer.filteredReceiptRows(TaskCenterReceiptFilter(status: status, includeArchived: true))
                .allSatisfy { !controlIDs.contains($0.taskID) })
        }
        let diagnostics = consumer.sessionActionDiagnosticObservation()
        #expect(Set(diagnostics.taskSnapshots.map(\.taskID)) == controlIDs)
        let reopened = try AgentTaskStore(persistenceURL: ledgerURL)
        let restored = TaskCenterControlConsumer(store: reopened)
        #expect(restored.receiptRows(includeArchived: true) == consumer.receiptRows(includeArchived: true))
        #expect(restored.sessionActionDiagnosticObservation() == diagnostics)
        #expect(reopened.taskCenterSnapshots(includeArchived: true) == canonicalBefore)
        #expect(reopened.allReceipts() == receiptsBefore)
        #expect(try Data(contentsOf: ledgerURL) == bytesBefore)
        #expect(bridge.chat.activeSessionID == activeSession && bridge.chat.messages == messages)
        #expect(throws: SessionActionError.invalidTarget) {
            _ = try bridge.performSessionAction(.switch(sessionID: UUID().uuidString))
        }
        #expect(tasks.taskCenterSnapshots(includeArchived: true) == canonicalBefore)
        #expect(tasks.allReceipts() == receiptsBefore)
        #expect(try Data(contentsOf: ledgerURL) == bytesBefore)
        #expect(bridge.chat.activeSessionID == activeSession && bridge.chat.messages == messages)
        // Preserve this wholly synthetic root as evidence; no deletion is performed.
    }
}
