import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("2443 scheduler Task Center reads canonical recovery lineage")
@MainActor
struct SchedulerTaskCenterLineage2443Tests {
    private func bridge(
        scheduler: SchedulerTaskStore,
        root: URL,
        defaults: UserDefaults
    ) -> BridgeStore {
        BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            settingsCatalogSchedulerStore: scheduler,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            canvasRuntimeState: .disabled,
            agentTaskStore: AgentTaskStore(),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            taskCenterBindingPersistenceURL: root.appendingPathComponent("bindings.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
            }
        )
    }

    private func schedulerRows(_ bridge: BridgeStore) throws -> [[String: Any]] {
        let output = bridge.executeTaskCenterSlashCommand("/scheduler")
        let object = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(object["ok"] as? Bool == true)
        let payload = try #require(object["payload"] as? [String: Any])
        return try #require(payload["occurrences"] as? [[String: Any]])
    }

    @Test func healthyRunThenRestartUnknownRequiresReviewAndExplicitNewAttempt() throws {
        let resolvedPaths = try FormalTestIsolationPaths.resolveCurrentProcess()
        let paths = try #require(resolvedPaths)
        let root = paths.rootDirectory.appendingPathComponent("scheduler2443-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "scheduler2443." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = root.appendingPathComponent("occurrences.json")
        let scheduler = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(scheduler.add(
            name: "canonical scheduler", cronExpression: "* * * * *",
            command: "PRIVATE_PROMPT_2443", targetSessionID: UUID(),
            targetProjectID: "synthetic-project", targetTurnID: 1
        ) == nil)
        let task = try #require(scheduler.allTasks().first)
        #expect(scheduler.authorize(task.id))
        let now = Date(timeIntervalSince1970: 1_756_650_000)
        let occurrence = try #require(scheduler.reserveOccurrence(taskID: task.id, at: now))
        let transitions: [(SchedulerOccurrenceState, SchedulerOccurrenceState)] = [
            (SchedulerOccurrenceState.triggered, .authorized),
            (.authorized, .admitted),
            (.admitted, .dispatched),
        ]
        for (before, after) in transitions {
            #expect(scheduler.compareAndSwapOccurrence(
                id: occurrence.id, expected: before, next: after,
                expectedControlRevision: task.version, now: now
            ))
        }
        let token = try #require(scheduler.claimLease(
            id: occurrence.id, owner: "healthy-owner", expectedControlRevision: task.version,
            now: now, ttl: 300
        ))
        #expect(scheduler.heartbeat(id: occurrence.id, owner: "healthy-owner", token: token,
                                    now: now, ttl: 300))

        let liveRows = try schedulerRows(bridge(scheduler: scheduler, root: root, defaults: defaults))
        let live = try #require(liveRows.first)
        #expect(live["state"] as? String == "running")
        #expect(live["task_version"] as? Int == task.version)
        #expect(live["recovery_action"] as? String == "none")
        #expect(live["requires_user_action"] as? Bool == false)
        let liveJSON = try JSONSerialization.data(withJSONObject: liveRows)
        #expect(String(data: liveJSON, encoding: .utf8)?.contains("PRIVATE_PROMPT_2443") == false)

        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(reopened.reconcileExpiredOccurrences(now: now.addingTimeInterval(1)) == 1)
        let unknownRows = try schedulerRows(bridge(scheduler: reopened, root: root, defaults: defaults))
        let unknown = try #require(unknownRows.first)
        #expect(unknown["state"] as? String == "unknown")
        #expect(unknown["recovery_action"] as? String == "reconcile")
        #expect(unknown["requires_user_action"] as? Bool == true)
        #expect(unknownRows.count == 1)
        #expect(reopened.retryUnknownOccurrence(
            id: occurrence.id, expectedControlRevision: task.version,
            proofToken: "missing-proof", now: now.addingTimeInterval(2)
        ) == nil)
        #expect(reopened.reconcileUnknownOccurrence(id: occurrence.id, now: now.addingTimeInterval(2)))
        let proof = try #require(reopened.occurrence(id: occurrence.id)?.reconciliationProof)
        let retry = try #require(reopened.retryUnknownOccurrence(
            id: occurrence.id, expectedControlRevision: task.version,
            proofToken: proof, now: now.addingTimeInterval(2)
        ))
        let retryRows = try schedulerRows(bridge(scheduler: reopened, root: root, defaults: defaults))
        let newAttempt = try #require(retryRows.first {
            $0["occurrence_id"] as? String == retry.id.uuidString.lowercased()
        })
        #expect(newAttempt["task_version"] as? Int == task.version)
        #expect(newAttempt["retry_of_occurrence_id"] as? String == occurrence.id.uuidString.lowercased())
        #expect(newAttempt["state"] as? String == "triggered")
        #expect(retryRows.count == 2)
    }

    @Test func corruptCanonicalLedgerNeverAppearsAsAnEmptySuccessfulScheduler() throws {
        let resolvedPaths = try FormalTestIsolationPaths.resolveCurrentProcess()
        let paths = try #require(resolvedPaths)
        let root = paths.rootDirectory.appendingPathComponent("scheduler2443-corrupt-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "scheduler2443.corrupt." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try Data("{invalid-ledger".utf8).write(to: root.appendingPathComponent("occurrences.json"))
        let scheduler = SchedulerTaskStore(
            defaults: defaults, occurrenceLedgerURL: root.appendingPathComponent("occurrences.json")
        )
        #expect(scheduler.persistenceError != nil)
        let output = bridge(scheduler: scheduler, root: root, defaults: defaults)
            .executeTaskCenterSlashCommand("/scheduler")
        let object = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(object["ok"] as? Bool == false)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "scheduler_unavailable")
    }
}
