import AppKit
import ApplicationServices
import Foundation
import Testing
import SwiftUI
@testable import MinisCanvasApp

@MainActor
private struct SchedulerDeletionFixture {
    let suiteName: String
    let defaults: UserDefaults
    let directory: URL
    let ledgerURL: URL
    let store: SchedulerTaskStore

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    func snapshot() -> SchedulerDeletionSnapshot {
        SchedulerDeletionSnapshot(
            tasks: store.tasks,
            occurrences: store.occurrences,
            journal: store.occurrenceJournal,
            persistedTasks: defaults.data(forKey: "miniscanvas.scheduler.tasks.v1"),
            persistedLedger: schedulerRegularFileData(at: ledgerURL)
        )
    }
}

private struct SchedulerDeletionSnapshot: Equatable {
    let tasks: [SchedulerTask]
    let occurrences: [SchedulerOccurrence]
    let journal: [SchedulerOccurrenceJournalEntry]
    let persistedTasks: Data?
    let persistedLedger: Data?
}

@MainActor
private final class SchedulerControlCASRequestCapture {
    var requests: [SchedulerSubmissionRequest] = []
}

@Suite("F16 scheduler control settings consumer")
@MainActor
struct SchedulerControlSettingsTests {
    private func makeStore() -> (SchedulerTaskStore, () -> Void) {
        let suite = "scheduler-control-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-control-settings-\(UUID().uuidString)", isDirectory: true)
        let store = SchedulerTaskStore(
            defaults: defaults,
            occurrenceLedgerURL: directory.appendingPathComponent("occurrences.json")
        )
        return (store, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    private func makeDeletionFixture() -> SchedulerDeletionFixture {
        let suite = "scheduler-delete-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-delete-settings-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledgerURL = directory.appendingPathComponent("occurrences.json")
        return SchedulerDeletionFixture(
            suiteName: suite,
            defaults: defaults,
            directory: directory,
            ledgerURL: ledgerURL,
            store: SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledgerURL)
        )
    }

    @Test
    func fullControlViewUsesInjectedExistingRuntimeBoundary() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let runtime = SchedulerTaskRuntime(store: store, submitCommand: { _ in })
        let view = SchedulerControlSettingsView(store: store, runtime: runtime)
        _ = view.body
        #expect(store.allTasks().isEmpty)
        #expect(!runtime.isStarted)
    }

    @Test
    func previewConfirmRejectsMutatedTargetAndExpiredVersion() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.add(
            name: "目标门禁",
            cronExpression: "0 * * * *",
            command: "run-v1",
            targetSessionID: UUID(),
            targetProjectID: "project-f16",
            targetTurnID: 1
        )
        let task = store.allTasks()[0]
        let now = Date(timeIntervalSince1970: 1_756_650_000)
        let preview = store.preview(taskID: task.id, now: now, timeZone: TimeZone(secondsFromGMT: 0)!)!
        var edited = task
        edited.targetProjectID = "project-mutated"
        #expect(store.update(edited) == nil)
        #expect(store.confirmPreview(
            preview,
            actorID: "user-f16",
            scopeID: "project-f16",
            policyRevision: "scheduler-policy-v1",
            now: now
        ) == false)
        #expect(store.task(id: task.id)?.isAuthorized == false)
    }

    @Test("D-SCHEDA creation previews exact facts and cannot execute before explicit confirmation")
    func newScheduleRequiresFreshFourFactPreviewBeforeExecution() throws {
        let fixture = makeDeletionFixture()
        defer { fixture.cleanup() }
        let sessionID = UUID()
        let now = Date(timeIntervalSince1970: 1_756_650_000)
        let digest = String(repeating: "a", count: 64)
        let preflight = SchedulerProviderPreflight(
            providerID: "synthetic-provider", modelID: "synthetic-model",
            credentialVersion: "apply:synthetic-v1", status: .ready, detail: "ready"
        )
        fixture.store.providerPreflightResolver = { _, _ in preflight }
        #expect(fixture.store.add(name: "待确认计划", cronExpression: "* * * * *",
            command: "synthetic-run", targetSessionID: sessionID,
            targetProjectID: "scope-a", targetTurnID: 1) == nil)
        let created = try #require(fixture.store.allTasks().first)
        var preview = try #require(fixture.store.preview(taskID: created.id, now: now,
            timeZone: TimeZone(identifier: "UTC")))
        preview.observedSourceAnchorDigest = digest
        preview.observedPolicyRevision = "policy-v1"
        let projection = SchedulerControlProductionProjection(preview: preview, occurrences: fixture.store.occurrences)
        #expect(projection.trigger.cronExpression == "* * * * *")
        #expect(projection.trigger.nextOccurrence != nil)
        #expect(projection.credential.providerID == "synthetic-provider")
        #expect(projection.credential.credentialVersion == "apply:synthetic-v1")
        #expect(projection.target.sessionID == sessionID)
        #expect(projection.target.projectID == "scope-a")
        #expect(projection.target.turnID == 1)
        #expect(projection.pinnedVersion.taskVersion == created.version)
        #expect(projection.authorizationState == .waiting)
        #expect(!projection.canProduceDispatchIntent)

        let capture = SchedulerControlCASRequestCapture()
        let runtime = SchedulerTaskRuntime(store: fixture.store, submitRequest: { capture.requests.append($0) })
        runtime.pollNow(at: try #require(projection.nextOccurrence))
        #expect(capture.requests.isEmpty)
        #expect(!fixture.store.occurrences.isEmpty)
        #expect(fixture.store.occurrences.allSatisfy { $0.state == .waitingApproval })
        #expect(fixture.store.occurrences.allSatisfy { $0.submissionReceipt == nil })

        var edited = created
        edited.targetProjectID = "scope-b"
        #expect(fixture.store.update(edited, expectedVersion: created.version) == nil)
        #expect(!fixture.store.confirmPreview(preview, actorID: "synthetic-actor", scopeID: "scope-a",
            policyRevision: "policy-v1", now: now, sourceAnchorConfirmed: true,
            currentSourceAnchorDigest: digest, currentPolicyRevision: "policy-v1"))
        let current = try #require(fixture.store.task(id: created.id))
        #expect(current.version > preview.taskVersion)
        #expect(!current.isAuthorized)

        var fresh = try #require(fixture.store.preview(taskID: created.id, now: now,
            timeZone: TimeZone(identifier: "UTC")))
        fresh.observedSourceAnchorDigest = digest
        fresh.observedPolicyRevision = "policy-v1"
        #expect(fresh.targetProjectID == "scope-b")
        #expect(fresh.taskVersion == current.version)
        #expect(fixture.store.confirmPreview(fresh, actorID: "synthetic-actor", scopeID: "scope-b",
            policyRevision: "policy-v1", now: now, sourceAnchorConfirmed: true,
            currentSourceAnchorDigest: digest, currentPolicyRevision: "policy-v1"))

        let reopened = SchedulerTaskStore(defaults: fixture.defaults, occurrenceLedgerURL: fixture.ledgerURL)
        let authorized = try #require(reopened.task(id: created.id))
        #expect(authorized.isAuthorized)
        #expect(authorized.authorizationActorID == "synthetic-actor")
        #expect(authorized.authorizationScopeID == "scope-b")
        #expect(authorized.sourceAnchorDigest == digest)
        #expect(reopened.occurrences.allSatisfy { $0.submissionReceipt == nil })
    }

    @Test("生产投影绑定触发、凭据、目标、版本和授权，并拒绝缺凭据 dispatch")
    func productionProjectionBlocksMissingCredential() {
        let now = Date(timeIntervalSince1970: 1_756_650_000)
        let digest = String(repeating: "a", count: 64)
        let taskID = UUID()
        let targetSessionID = UUID()
        func preview(status: SchedulerProviderPreflightStatus) -> SchedulerTaskPreview {
            SchedulerTaskPreview(
                taskID: taskID,
                taskVersion: 7,
                name: "投影任务",
                cronExpression: "* * * * *",
                command: "run",
                targetSessionID: targetSessionID,
                targetProjectID: "project",
                targetTurnID: 3,
                sourceAnchorVersion: 2,
                observedSourceAnchorDigest: digest,
                observedPolicyRevision: "policy-v7",
                isEnabled: true,
                authorizationActorID: "actor",
                authorizationScopeID: "project",
                authorizationPolicyRevision: "policy-v7",
                authorizationExpiresAt: now.addingTimeInterval(60),
                authorizationRevoked: false,
                authorizationState: .authorized,
                timeZoneIdentifier: "UTC",
                predictedTriggers: [now.addingTimeInterval(60)],
                fingerprint: "fingerprint-v7",
                expiresAt: now.addingTimeInterval(60),
                providerPreflight: SchedulerProviderPreflight(
                    providerID: "OpenAI",
                    modelID: "gpt-5.5",
                    credentialVersion: "apply:credential-v7",
                    status: status,
                    detail: status == .ready ? "ready" : "credential unavailable"
                )
            )
        }

        let ready = SchedulerControlProductionProjection(
            preview: preview(status: .ready),
            occurrences: []
        )
        #expect(ready.trigger.isValid)
        #expect(ready.nextOccurrence == now.addingTimeInterval(60))
        #expect(ready.credential.credentialVersion == "apply:credential-v7")
        #expect(ready.source.isBound)
        #expect(ready.source.displayValue.contains("policy-v7"))
        #expect(ready.target.isValid)
        #expect(ready.pinnedVersion.taskVersion == 7)
        #expect(ready.canProduceDispatchIntent)

        let blocked = SchedulerControlProductionProjection(
            preview: preview(status: .missingCredential),
            occurrences: []
        )
        #expect(blocked.credential.status == .missingCredential)
        #expect(!blocked.credential.isReadyForExecution)
        #expect(!blocked.canProduceDispatchIntent)
    }

    @Test("实际暂停/恢复写边界拒旧版，fresh 成功并持久重开", arguments: [false, true])
    func actualEnablementCASRejectsStaleVersionWithoutWrites(enabled: Bool) throws {
        let fixture = makeDeletionFixture()
        defer { fixture.cleanup() }
        #expect(fixture.store.add(name: "CAS task", cronExpression: "* * * * *",
                                  command: "owned command", isEnabled: !enabled) == nil)
        let original: SchedulerTask = try #require(fixture.store.allTasks().first)
        if original.isEnabled {
            let reserved: SchedulerOccurrence = try #require(fixture.store.reserveOccurrence(
                taskID: original.id, at: Date(timeIntervalSince1970: 1_756_650_000), calendar: utcCalendar))
            #expect(reserved.taskID == original.id)
        }
        var edited = original
        edited.name = "CAS task v2"
        #expect(fixture.store.update(edited, expectedVersion: original.version) == nil)
        let current: SchedulerTask = try #require(fixture.store.task(id: original.id))
        #expect(current.version == original.version + 1)
        let before = fixture.snapshot()

        // The same store API is called by the production Toggle consumer.
        // A stale version must lose before task, ledger or journal mutation.
        #expect(!fixture.store.setEnabled(original.id, enabled: enabled,
                                         expectedVersion: original.version,
                                         expectedEnablementRevision: original.enablementRevision))
        #expect(fixture.snapshot() == before)
        #expect(fixture.store.persistenceError == nil)

        #expect(fixture.store.setEnabled(current.id, enabled: enabled,
                                        expectedVersion: current.version,
                                        expectedEnablementRevision: current.enablementRevision))
        let committed: SchedulerTask = try #require(fixture.store.task(id: current.id))
        var expected = current
        expected.isEnabled = enabled
        expected.enablementRevision += 1
        #expect(committed == expected, "开关不修改定义版本或授权事实")
        if !enabled {
            #expect(fixture.store.occurrences.allSatisfy { $0.state == .cancelled })
            #expect(fixture.store.occurrenceJournal.last?.state == .cancelled)
        }
        let committedState = fixture.snapshot()
        let reopened = SchedulerTaskStore(defaults: fixture.defaults,
                                          occurrenceLedgerURL: fixture.ledgerURL)
        #expect(reopened.task(id: current.id) == committed)
        #expect(reopened.occurrences == committedState.occurrences)
        #expect(reopened.occurrenceJournal == committedState.journal)
        #expect(fixture.defaults.data(forKey: "miniscanvas.scheduler.tasks.v1")
                == committedState.persistedTasks)
        #expect(schedulerRegularFileData(at: fixture.ledgerURL) == committedState.persistedLedger)
    }

    @Test("暂停 ledger 写失败回滚 exact before-image 并报告失败")
    func enablementCASLedgerFailureRestoresBeforeImage() throws {
        let fixture = makeDeletionFixture()
        defer { fixture.cleanup() }
        #expect(fixture.store.add(name: "CAS rollback", cronExpression: "* * * * *",
                                  command: "owned command") == nil)
        let task: SchedulerTask = try #require(fixture.store.allTasks().first)
        let reserved: SchedulerOccurrence = try #require(fixture.store.reserveOccurrence(
            taskID: task.id, at: Date(timeIntervalSince1970: 1_756_650_000), calendar: utcCalendar))
        #expect(reserved.taskID == task.id)
        // Use the existing fixture's owned-directory obstruction, while
        // preserving the committed ledger bytes beside it for recovery proof.
        let savedLedger = fixture.directory.appendingPathComponent("ledger-before.json")
        try FileManager.default.moveItem(at: fixture.ledgerURL, to: savedLedger)
        try FileManager.default.createDirectory(at: fixture.ledgerURL,
                                               withIntermediateDirectories: false)
        let before = fixture.snapshot()
        let savedBytes = try Data(contentsOf: savedLedger)
        #expect(!fixture.store.setEnabled(task.id, enabled: false, expectedVersion: task.version,
                                         expectedEnablementRevision: task.enablementRevision))
        #expect(fixture.store.persistenceError == .ledgerWriteFailed(path: fixture.ledgerURL.path))
        #expect(fixture.snapshot() == before)
        #expect(fixture.store.task(id: task.id)?.enablementRevision == task.enablementRevision)
        #expect(try Data(contentsOf: savedLedger) == savedBytes)
    }

    @Test("真实取消 CAS 拒旧版，跨分钟/重开零旧 occurrence 派发且 sibling 为活正控")
    func cancelCASRejectsStaleThenFencesOnlyCancelledOccurrenceAcrossMinutes() throws {
        let fixture = makeDeletionFixture()
        defer { fixture.cleanup() }
        let date = Date(timeIntervalSince1970: 1_756_650_000)
        let components = utcCalendar.dateComponents([.hour, .minute], from: date)
        let hour: Int = try #require(components.hour)
        let minute: Int = try #require(components.minute)
        let cron = "\(minute) \(hour) * * *"
        for name in ["cancel target", "live sibling"] {
            let schedule = name == "live sibling" ? "* * * * *" : cron
            #expect(fixture.store.add(name: name, cronExpression: schedule, command: name,
                targetSessionID: UUID(), targetProjectID: "owned-cas-project", targetTurnID: 7) == nil)
        }
        let original: SchedulerTask = try #require(fixture.store.allTasks().first { $0.name == "cancel target" })
        let sibling: SchedulerTask = try #require(fixture.store.allTasks().first { $0.name == "live sibling" })
        var edited = original
        edited.command = "cancel target v2"
        edited.timeZoneIdentifier = "UTC"
        #expect(fixture.store.update(edited, expectedVersion: original.version) == nil)
        var siblingInUTC = sibling
        siblingInUTC.timeZoneIdentifier = "UTC"
        #expect(fixture.store.update(siblingInUTC, expectedVersion: sibling.version) == nil)
        #expect(fixture.store.authorize(original.id))
        #expect(fixture.store.authorize(sibling.id))
        let target: SchedulerTask = try #require(fixture.store.task(id: original.id))
        let queued: SchedulerOccurrence = try #require(fixture.store.reserveOccurrence(
            taskID: target.id, at: date, calendar: utcCalendar))
        let capture = SchedulerControlCASRequestCapture()
        let runtime = SchedulerTaskRuntime(store: fixture.store, submitRequest: { request in
            capture.requests.append(request)
        })
        let beforeStale = fixture.snapshot()
        #expect(!runtime.cancelOccurrence(id: queued.id, expectedTaskVersion: original.version,
            expectedControlRevision: queued.controlRevision, now: date))
        #expect(fixture.snapshot() == beforeStale)
        #expect(capture.requests.isEmpty)
        #expect(runtime.cancelOccurrence(id: queued.id, expectedTaskVersion: queued.taskVersion,
            expectedControlRevision: queued.controlRevision, now: date))
        let cancelled: SchedulerOccurrence = try #require(fixture.store.occurrence(id: queued.id))
        #expect(cancelled.state == .cancelled)
        #expect(cancelled.deliveryReceipt == nil && cancelled.submissionReceipt == nil)
        runtime.pollNow(at: date, calendar: utcCalendar)
        #expect(capture.requests.count == 1)
        let handedOff: SchedulerSubmissionRequest = try #require(capture.requests.first)
        #expect(handedOff.taskID == sibling.id && handedOff.occurrenceID != queued.id)
        #expect(fixture.store.occurrence(id: handedOff.occurrenceID)?.state == .unknown,
                "legacy callback只证实handoff，不伪造delivered")
        let cancelledJournal = fixture.store.occurrenceJournal.filter { $0.occurrenceID == queued.id }
        for offset in [60.0, 120.0, 180.0] {
            runtime.pollNow(at: date.addingTimeInterval(offset), calendar: utcCalendar)
        }
        #expect(capture.requests.count == 4, "每个新分钟的合法 sibling occurrence 仍正常 handoff")
        #expect(capture.requests.allSatisfy { $0.taskID == sibling.id && $0.occurrenceID != queued.id })
        #expect(Set(capture.requests.map(\.occurrenceID)).count == 4)
        #expect(fixture.store.occurrence(id: queued.id) == cancelled)
        #expect(fixture.store.occurrenceJournal.filter { $0.occurrenceID == queued.id } == cancelledJournal)
        let afterLiveControl = fixture.snapshot()
        let reopened = SchedulerTaskStore(defaults: fixture.defaults,
                                          occurrenceLedgerURL: fixture.ledgerURL)
        let reopenedRuntime = SchedulerTaskRuntime(store: reopened, submitRequest: { request in
            capture.requests.append(request)
        })
        for offset in [0.0, 60.0, 180.0] {
            reopenedRuntime.pollNow(at: date.addingTimeInterval(offset), calendar: utcCalendar)
        }
        #expect(capture.requests.count == 4)
        #expect(reopened.occurrence(id: queued.id) == cancelled)
        #expect(reopened.occurrences == afterLiveControl.occurrences)
        #expect(reopened.occurrenceJournal == afterLiveControl.journal)
        #expect(fixture.defaults.data(forKey: "miniscanvas.scheduler.tasks.v1")
                == afterLiveControl.persistedTasks)
        #expect(schedulerRegularFileData(at: fixture.ledgerURL) == afterLiveControl.persistedLedger)
        #expect(!reopenedRuntime.cancelOccurrence(id: queued.id,
            expectedTaskVersion: queued.taskVersion,
            expectedControlRevision: queued.controlRevision, now: date.addingTimeInterval(180)))
        #expect(reopened.occurrences == afterLiveControl.occurrences)
        #expect(reopened.occurrenceJournal == afterLiveControl.journal)
        #expect(fixture.defaults.data(forKey: "miniscanvas.scheduler.tasks.v1")
                == afterLiveControl.persistedTasks)
        #expect(schedulerRegularFileData(at: fixture.ledgerURL) == afterLiveControl.persistedLedger)
    }

    @Test("连续开关及 ABA 后旧控制快照不得再写", arguments: [false, true])
    func capturedControlSnapshotRejectsContinuousAndABAToggles(aba: Bool) throws {
        let fixture = makeDeletionFixture()
        defer { fixture.cleanup() }
        #expect(fixture.store.add(name: "control snapshot", cronExpression: "* * * * *",
                                  command: "owned command") == nil)
        let original: SchedulerTask = try #require(fixture.store.allTasks().first)
        let queued: SchedulerOccurrence = try #require(fixture.store.reserveOccurrence(
            taskID: original.id, at: Date(timeIntervalSince1970: 1_756_650_000), calendar: utcCalendar))
        #expect(fixture.store.setEnabled(original.id, enabled: false,
                                        expectedVersion: original.version,
                                         expectedEnablementRevision: original.enablementRevision))
        let paused: SchedulerTask = try #require(fixture.store.task(id: original.id))
        #expect(paused.version == original.version)
        #expect(paused.enablementRevision == original.enablementRevision + 1)
        #expect(fixture.store.occurrence(id: queued.id)?.state == .cancelled)
        if aba {
            #expect(fixture.store.setEnabled(paused.id, enabled: true,
                                            expectedVersion: paused.version,
                                            expectedEnablementRevision: paused.enablementRevision))
        }
        let beforeStale = fixture.snapshot()
        let desiredState = !aba
        // Without ABA this is an old resume; after ABA it is an old pause.
        // The captured definition version is still v1 in both cases, so a
        // definition-only check must not be mistaken for a control CAS.
        #expect(!fixture.store.setEnabled(original.id, enabled: desiredState,
                                         expectedVersion: original.version,
                                         expectedEnablementRevision: original.enablementRevision))
        #expect(fixture.snapshot() == beforeStale)
        let current: SchedulerTask = try #require(fixture.store.task(id: original.id))
        #expect(current.version == original.version)
        #expect(fixture.store.setEnabled(current.id, enabled: desiredState,
                                        expectedVersion: current.version,
                                        expectedEnablementRevision: current.enablementRevision))
        #expect(fixture.store.task(id: current.id)?.isEnabled == desiredState)
        #expect(fixture.store.task(id: current.id)?.version == original.version)
        #expect(fixture.store.occurrence(id: queued.id)?.state == .cancelled)
        let committed = fixture.snapshot()
        let reopened = SchedulerTaskStore(defaults: fixture.defaults,
                                          occurrenceLedgerURL: fixture.ledgerURL)
        #expect(reopened.task(id: current.id) == fixture.store.task(id: current.id))
        #expect(reopened.occurrences == committed.occurrences)
        #expect(reopened.occurrenceJournal == committed.journal)
        #expect(fixture.defaults.data(forKey: "miniscanvas.scheduler.tasks.v1") == committed.persistedTasks)
        #expect(schedulerRegularFileData(at: fixture.ledgerURL) == committed.persistedLedger)
    }

    @Test("控制 revision 持久重开、fresh/noop 和定义 update 不回退 counter")
    func enablementRevisionPersistsAndFreshNoopIsWriteFree() throws {
        let fixture = makeDeletionFixture()
        defer { fixture.cleanup() }
        #expect(fixture.store.add(name: "counter", cronExpression: "* * * * *", command: "owned") == nil)
        let original: SchedulerTask = try #require(fixture.store.allTasks().first)
        #expect(original.enablementRevision == 1)
        let beforeNoop = fixture.snapshot()
        #expect(fixture.store.setEnabled(original.id, enabled: original.isEnabled,
            expectedVersion: original.version, expectedEnablementRevision: original.enablementRevision))
        #expect(fixture.snapshot() == beforeNoop)
        #expect(fixture.store.setEnabled(original.id, enabled: false,
            expectedVersion: original.version, expectedEnablementRevision: original.enablementRevision))
        let paused: SchedulerTask = try #require(fixture.store.task(id: original.id))
        #expect(paused.enablementRevision == 2 && paused.version == original.version)
        let beforeStaleNoop = fixture.snapshot()
        #expect(!fixture.store.setEnabled(original.id, enabled: false,
            expectedVersion: original.version, expectedEnablementRevision: original.enablementRevision))
        #expect(fixture.snapshot() == beforeStaleNoop, "陈旧请求即便目标已同状态也须先拒绝")
        let reopened = SchedulerTaskStore(defaults: fixture.defaults, occurrenceLedgerURL: fixture.ledgerURL)
        #expect(reopened.task(id: original.id) == paused)
        #expect(reopened.setEnabled(paused.id, enabled: true,
            expectedVersion: paused.version, expectedEnablementRevision: paused.enablementRevision))
        let resumed: SchedulerTask = try #require(reopened.task(id: original.id))
        #expect(resumed.enablementRevision == 3 && resumed.version == original.version)
        var oldDefinition = original
        oldDefinition.name = "edited after controls"
        let beforeStaleDefinition = reopened.tasks
        let beforeStaleBytes = fixture.defaults.data(forKey: "miniscanvas.scheduler.tasks.v1")
        #expect(reopened.update(oldDefinition, expectedVersion: original.version) != nil)
        #expect(reopened.tasks == beforeStaleDefinition)
        #expect(fixture.defaults.data(forKey: "miniscanvas.scheduler.tasks.v1") == beforeStaleBytes)
        var freshDefinition = resumed
        freshDefinition.name = oldDefinition.name
        #expect(reopened.update(freshDefinition, expectedVersion: freshDefinition.version,
                                expectedEnablementRevision: freshDefinition.enablementRevision) == nil)
        let edited: SchedulerTask = try #require(reopened.task(id: original.id))
        var expected = freshDefinition
        expected.version += 1
        #expect(edited == expected, "旧定义副本不得把已提交 control revision 回退")
        let finalReload = SchedulerTaskStore(defaults: fixture.defaults, occurrenceLedgerURL: fixture.ledgerURL)
        #expect(finalReload.task(id: original.id) == edited)
    }

    @Test("仅缺 key legacy 解为1，首次开关保存 counter 并重开")
    func legacyMissingEnablementRevisionMigratesOnActualToggle() throws {
        let fixture = makeDeletionFixture()
        defer { fixture.cleanup() }
        let task = SchedulerTask(name: "legacy", cronExpression: "* * * * *", command: "owned")
        let encoded = try JSONEncoder().encode(task)
        var object: [String: Any] = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "enablementRevision")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SchedulerTask.self, from: legacy)
        #expect(decoded == task && decoded.enablementRevision == 1)
        let legacyArray = try JSONSerialization.data(withJSONObject: [object])
        fixture.defaults.set(legacyArray, forKey: "miniscanvas.scheduler.tasks.v1")
        let loaded = SchedulerTaskStore(defaults: fixture.defaults, occurrenceLedgerURL: fixture.ledgerURL)
        #expect(loaded.task(id: task.id) == decoded)
        #expect(fixture.defaults.data(forKey: "miniscanvas.scheduler.tasks.v1") == legacyArray,
                "只读 legacy load 不回写或迁移字节")
        #expect(loaded.setEnabled(task.id, enabled: false, expectedVersion: decoded.version,
                                 expectedEnablementRevision: decoded.enablementRevision))
        let paused: SchedulerTask = try #require(loaded.task(id: task.id))
        var expected = task
        expected.isEnabled = false
        expected.enablementRevision = 2
        #expect(paused == expected)
        let reopened = SchedulerTaskStore(defaults: fixture.defaults, occurrenceLedgerURL: fixture.ledgerURL)
        #expect(reopened.task(id: task.id) == expected)
        #expect(reopened.persistenceError == nil)
        #expect(reopened.add(name: "valid legacy add", cronExpression: "* * * * *", command: "owned new") == nil)
        let afterAdd = SchedulerTaskStore(defaults: fixture.defaults, occurrenceLedgerURL: fixture.ledgerURL)
        #expect(afterAdd.persistenceError == nil && afterAdd.allTasks().count == 2)
        #expect(afterAdd.task(id: task.id) == expected)
        #expect(afterAdd.allTasks().filter { $0.id != task.id }.count == 1)
    }

    @Test("present null/非整/非正 counter 必须拒绝且不改原持久字节",
          arguments: ["null", "zero", "negative", "fraction", "string", "boolean"])
    func malformedEnablementRevisionRejectsWithoutMutation(kind: String) throws {
        let fixture = makeDeletionFixture()
        defer { fixture.cleanup() }
        let task = SchedulerTask(name: "malformed", cronExpression: "* * * * *", command: "owned")
        var object: [String: Any] = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(task)) as? [String: Any])
        switch kind {
        case "null": object["enablementRevision"] = NSNull()
        case "zero": object["enablementRevision"] = 0
        case "negative": object["enablementRevision"] = -1
        case "fraction": object["enablementRevision"] = 1.5
        case "string": object["enablementRevision"] = "1"
        case "boolean": object["enablementRevision"] = true
        default: Issue.record("未知无效输入"); return
        }
        let malformed = try JSONSerialization.data(withJSONObject: object)
        do {
            _ = try JSONDecoder().decode(SchedulerTask.self, from: malformed)
            Issue.record("present 无效 control revision 被错误接受")
        } catch is DecodingError {
            // The actual Codable producer rejects; no silent default to legacy 1.
        }
        #expect(fixture.store.add(name: "valid sibling retained in bytes", cronExpression: "* * * * *",
                                  command: "owned sibling") == nil)
        let valid: SchedulerTask = try #require(fixture.store.allTasks().first)
        let queued: SchedulerOccurrence = try #require(fixture.store.reserveOccurrence(
            taskID: valid.id, at: Date(timeIntervalSince1970: 1_756_650_000), calendar: utcCalendar))
        #expect(queued.taskID == valid.id && queued.state == .triggered)
        let preservedLedger: Data = try #require(schedulerRegularFileData(at: fixture.ledgerURL))
        let validObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid))
        let bytes = try JSONSerialization.data(withJSONObject: [validObject, object])
        fixture.defaults.set(bytes, forKey: "miniscanvas.scheduler.tasks.v1")
        let reopened = SchedulerTaskStore(defaults: fixture.defaults, occurrenceLedgerURL: fixture.ledgerURL)
        #expect(reopened.task(id: task.id) == nil && reopened.allTasks().isEmpty)
        let expectedError = SchedulerTaskStoreError.invalidTaskDefinitions(defaultsKey: "miniscanvas.scheduler.tasks.v1")
        #expect(reopened.persistenceError == expectedError)
        let beforeTasks = reopened.tasks
        let beforeOccurrences = reopened.occurrences
        let beforeJournal = reopened.occurrenceJournal
        #expect(reopened.add(name: "must not overwrite", cronExpression: "* * * * *", command: "owned new")
                == "任务存储不可用，请处理存储错误后重新打开。")
        #expect(reopened.update(valid, expectedVersion: valid.version,
                                expectedEnablementRevision: valid.enablementRevision)
                == "任务存储不可用，请处理存储错误后重新打开。")
        reopened.delete(id: valid.id)
        #expect(!reopened.authorize(valid.id))
        #expect(!reopened.revokeAuthorization(valid.id))
        #expect(reopened.reserveOccurrence(taskID: valid.id, at: Date()) == nil)
        #expect(reopened.reconcileExpiredOccurrences() == 0)
        let request: SchedulerTaskDeletionRequest = try #require(SchedulerTaskDeletionConsumer.request(for: valid))
        #expect(SchedulerTaskDeletionConsumer.confirm(request, selectedTaskID: valid.id, store: reopened)
                == .rejected(.existingPersistenceError))
        #expect(reopened.tasks == beforeTasks && reopened.occurrences == beforeOccurrences)
        #expect(reopened.occurrenceJournal == beforeJournal && reopened.persistenceError == expectedError)
        #expect(!reopened.setEnabled(task.id, enabled: false, expectedVersion: task.version,
                                    expectedEnablementRevision: 1))
        #expect(reopened.occurrences.isEmpty && reopened.occurrenceJournal.isEmpty)
        #expect(fixture.defaults.data(forKey: "miniscanvas.scheduler.tasks.v1") == bytes)
        #expect(schedulerRegularFileData(at: fixture.ledgerURL) == preservedLedger)
    }

    @Test("Int.max counter 拒绝变化，合法 noop 不升且 exact state/bytes 不变")
    func enablementRevisionOverflowIsWriteFree() throws {
        let fixture = makeDeletionFixture()
        defer { fixture.cleanup() }
        let task = SchedulerTask(name: "overflow", cronExpression: "* * * * *", command: "owned",
                                 enablementRevision: Int.max)
        fixture.defaults.set(try JSONEncoder().encode([task]), forKey: "miniscanvas.scheduler.tasks.v1")
        let reopened = SchedulerTaskStore(defaults: fixture.defaults, occurrenceLedgerURL: fixture.ledgerURL)
        #expect(reopened.task(id: task.id) == task)
        let beforeTasks = reopened.tasks
        let beforeOccurrences = reopened.occurrences
        let beforeJournal = reopened.occurrenceJournal
        let beforeBytes = fixture.defaults.data(forKey: "miniscanvas.scheduler.tasks.v1")
        let beforeLedger = schedulerRegularFileData(at: fixture.ledgerURL)
        #expect(!reopened.setEnabled(task.id, enabled: false, expectedVersion: task.version,
                                    expectedEnablementRevision: task.enablementRevision))
        var overflowEdit = task
        overflowEdit.isEnabled = false
        #expect(reopened.update(overflowEdit, expectedVersion: task.version,
                                expectedEnablementRevision: task.enablementRevision) != nil)
        #expect(reopened.setEnabled(task.id, enabled: true, expectedVersion: task.version,
                                   expectedEnablementRevision: task.enablementRevision))
        #expect(reopened.persistenceError == nil)
        #expect(reopened.tasks == beforeTasks && reopened.occurrences == beforeOccurrences)
        #expect(reopened.occurrenceJournal == beforeJournal)
        #expect(fixture.defaults.data(forKey: "miniscanvas.scheduler.tasks.v1") == beforeBytes)
        #expect(schedulerRegularFileData(at: fixture.ledgerURL) == beforeLedger)
    }

    @Test("ABA 旧预览拒绝，fresh 原预览确认可用且不换定义或授权身份")
    func enablementABAInvalidatesOnlyCapturedPreview() throws {
        let fixture = makeDeletionFixture()
        defer { fixture.cleanup() }
        #expect(fixture.store.add(name: "preview ABA", cronExpression: "* * * * *", command: "owned",
            targetSessionID: UUID(), targetProjectID: "owned-preview", targetTurnID: 1) == nil)
        let now = Date()
        let original: SchedulerTask = try #require(fixture.store.allTasks().first)
        #expect(fixture.store.authorize(original.id))
        let authorized: SchedulerTask = try #require(fixture.store.task(id: original.id))
        let preview: SchedulerTaskPreview = try #require(fixture.store.preview(taskID: original.id, now: now))
        #expect(fixture.store.setEnabled(authorized.id, enabled: false, expectedVersion: authorized.version,
                                        expectedEnablementRevision: authorized.enablementRevision))
        let paused: SchedulerTask = try #require(fixture.store.task(id: original.id))
        #expect(fixture.store.setEnabled(paused.id, enabled: true, expectedVersion: paused.version,
                                        expectedEnablementRevision: paused.enablementRevision))
        let resumed: SchedulerTask = try #require(fixture.store.task(id: original.id))
        var expected = authorized
        expected.enablementRevision += 2
        #expect(resumed == expected, "既有授权/定义/anchor不因控制counter变化而换身份")
        let beforeReject = fixture.snapshot()
        #expect(!fixture.store.confirmPreview(preview, actorID: authorized.authorizationActorID,
            scopeID: authorized.authorizationScopeID, policyRevision: authorized.authorizationPolicyRevision, now: now))
        #expect(fixture.snapshot() == beforeReject)
        let fresh: SchedulerTaskPreview = try #require(fixture.store.preview(taskID: original.id, now: now))
        #expect(fresh.fingerprint != preview.fingerprint && fresh.taskVersion == preview.taskVersion)
        #expect(fixture.store.confirmPreview(fresh, actorID: authorized.authorizationActorID,
            scopeID: authorized.authorizationScopeID, policyRevision: authorized.authorizationPolicyRevision, now: now))
        #expect(fixture.store.task(id: original.id) == resumed)
    }

    @Test("控制 counter 推进不使真实 running lease/原 request 失效，仍合法完成并重开")
    func runningLeaseCompletesAcrossEnablementRevisionChanges() throws {
        let fixture = makeDeletionFixture()
        defer { fixture.cleanup() }
        #expect(fixture.store.add(name: "running revision", cronExpression: "* * * * *", command: "owned",
            targetSessionID: UUID(), targetProjectID: "owned-running", targetTurnID: 1) == nil)
        var definition: SchedulerTask = try #require(fixture.store.allTasks().first)
        definition.sourceAnchorDigest = String(repeating: "a", count: 64)
        #expect(fixture.store.update(definition, expectedVersion: definition.version) == nil)
        #expect(fixture.store.authorize(definition.id))
        let authorized: SchedulerTask = try #require(fixture.store.task(id: definition.id))
        let now = Date(timeIntervalSince1970: 1_756_650_000)
        let queued: SchedulerOccurrence = try #require(fixture.store.reserveOccurrence(
            taskID: definition.id, at: now, calendar: utcCalendar))
        for (from, to) in [(SchedulerOccurrenceState.triggered, SchedulerOccurrenceState.authorized),
                           (.authorized, .admitted), (.admitted, .dispatched)] {
            #expect(fixture.store.compareAndSwapOccurrence(id: queued.id, expected: from, next: to,
                expectedControlRevision: queued.controlRevision, now: now))
        }
        let token: String = try #require(fixture.store.claimLease(id: queued.id, owner: "owned-running",
            expectedControlRevision: queued.controlRevision, now: now))
        #expect(fixture.store.heartbeat(id: queued.id, owner: "owned-running", token: token,
                                        now: now.addingTimeInterval(1)))
        let running: SchedulerOccurrence = try #require(fixture.store.occurrence(id: queued.id))
        let request = SchedulerSubmissionRequest(occurrenceID: running.id, effectID: running.effectID,
            taskID: authorized.id, taskVersion: running.taskVersion, idempotencyKey: running.idempotencyKey,
            command: running.command, targetSessionID: running.targetSessionID,
            targetProjectID: running.targetProjectID, targetTurnID: running.targetTurnID, sourceTaskID: authorized.id)
        #expect(fixture.store.setEnabled(authorized.id, enabled: false, expectedVersion: authorized.version,
                                        expectedEnablementRevision: authorized.enablementRevision))
        let paused: SchedulerTask = try #require(fixture.store.task(id: authorized.id))
        #expect(fixture.store.isSubmissionCurrent(request, owner: "owned-running", token: token,
                                                 now: now.addingTimeInterval(2)))
        #expect(fixture.store.setEnabled(paused.id, enabled: true, expectedVersion: paused.version,
                                        expectedEnablementRevision: paused.enablementRevision))
        #expect(fixture.store.occurrence(id: running.id) == running)
        #expect(fixture.store.isSubmissionCurrent(request, owner: "owned-running", token: token,
                                                 now: now.addingTimeInterval(2)))
        #expect(fixture.store.recordDelivery(id: running.id, owner: "owned-running", token: token,
            status: .delivered, now: now.addingTimeInterval(2), expectedTaskVersion: running.taskVersion,
            expectedControlRevision: running.controlRevision))
        let completed: SchedulerOccurrence = try #require(fixture.store.occurrence(id: running.id))
        #expect(completed.state == .succeeded && completed.deliveryReceipt?.status == .delivered)
        #expect(completed.taskVersion == running.taskVersion && completed.effectID == running.effectID)
        let resumed: SchedulerTask = try #require(fixture.store.task(id: authorized.id))
        var expected = authorized
        expected.enablementRevision += 2
        #expect(resumed == expected)
        let reopened = SchedulerTaskStore(defaults: fixture.defaults, occurrenceLedgerURL: fixture.ledgerURL)
        #expect(reopened.task(id: authorized.id) == resumed)
        #expect(reopened.occurrence(id: running.id) == completed)
        #expect(reopened.occurrenceJournal == fixture.store.occurrenceJournal)
    }

    @Test("暂停后旧编辑表单整组拒写；fresh rename/启停保原定义规则并精确推进counter")
    func definitionEditorCannotReplayCapturedEnablementState() throws {
        let fixture = makeDeletionFixture()
        defer { fixture.cleanup() }
        #expect(fixture.store.add(name: "editor CAS", cronExpression: "* * * * *", command: "owned") == nil)
        let original: SchedulerTask = try #require(fixture.store.allTasks().first)
        #expect(fixture.store.setEnabled(original.id, enabled: false, expectedVersion: original.version,
                                        expectedEnablementRevision: original.enablementRevision))
        let paused: SchedulerTask = try #require(fixture.store.task(id: original.id))
        #expect(!paused.isEnabled && paused.version == original.version)
        var staleForm = original
        staleForm.name = "stale editor must not resume"
        let beforeStale = fixture.snapshot()
        #expect(fixture.store.update(staleForm, expectedVersion: original.version,
                                    expectedEnablementRevision: original.enablementRevision) != nil)
        #expect(fixture.snapshot() == beforeStale)
        #expect(fixture.store.update(staleForm, expectedVersion: original.version) != nil,
                "旧调用省略参数仍使用入参捕获counter，不洗成current")
        #expect(fixture.snapshot() == beforeStale)
        var rename = paused
        rename.name = "fresh rename while paused"
        #expect(fixture.store.update(rename, expectedVersion: paused.version,
                                    expectedEnablementRevision: paused.enablementRevision) == nil)
        let renamed: SchedulerTask = try #require(fixture.store.task(id: original.id))
        var expectedRename = rename
        expectedRename.version += 1
        #expect(renamed == expectedRename && !renamed.isEnabled)
        #expect(renamed.enablementRevision == paused.enablementRevision)
        var freshForm = renamed
        freshForm.isEnabled = true
        #expect(fixture.store.update(freshForm, expectedVersion: renamed.version,
                                    expectedEnablementRevision: renamed.enablementRevision) == nil)
        let resumed: SchedulerTask = try #require(fixture.store.task(id: original.id))
        var expectedResumed = freshForm
        expectedResumed.version += 1
        expectedResumed.enablementRevision += 1
        #expect(resumed == expectedResumed)
        #expect(!resumed.isAuthorized && resumed.authorizationExpiresAt == nil)
        var freshPause = resumed
        freshPause.isEnabled = false
        #expect(fixture.store.update(freshPause, expectedVersion: resumed.version,
                                    expectedEnablementRevision: resumed.enablementRevision) == nil)
        let final: SchedulerTask = try #require(fixture.store.task(id: original.id))
        var expectedFinal = freshPause
        expectedFinal.version += 1
        expectedFinal.enablementRevision += 1
        #expect(final == expectedFinal)
        let reopened = SchedulerTaskStore(defaults: fixture.defaults, occurrenceLedgerURL: fixture.ledgerURL)
        #expect(reopened.task(id: original.id) == final && reopened.persistenceError == nil)
    }

    @Test("控制动作拒绝旧任务版本")
    func controlRevisionFenceRejectsStaleTask() {
        let task = SchedulerTask(name: "版本任务", cronExpression: "* * * * *", command: "run", version: 4)
        #expect(SchedulerControlTaskRevisionFence.matches(task, expectedVersion: 4))
        #expect(!SchedulerControlTaskRevisionFence.matches(task, expectedVersion: 3))
        #expect(!SchedulerControlTaskRevisionFence.matches(nil, expectedVersion: 4))
    }

    @Test("删除请求快照精确身份，打开请求本身不写入")
    func deletionRequestSnapshotsIdentityWithoutWriting() throws {
        let fixture = makeDeletionFixture()
        defer { fixture.cleanup() }
        fixture.store.add(name: "仅元数据任务", cronExpression: "0 9 * * *", command: "")
        let task = try #require(fixture.store.allTasks().first)
        let before = fixture.snapshot()
        let now = Date(timeIntervalSince1970: 1_788_800_000)

        let request = try #require(SchedulerTaskDeletionConsumer.request(for: task, now: now))

        #expect(request.taskID == task.id)
        #expect(request.taskVersion == task.version)
        #expect(request.taskName == task.name)
        #expect(request.requestedAt == now)
        #expect(request.expiresAt == now.addingTimeInterval(60))
        #expect(fixture.snapshot() == before)
    }

    @Test("选择变化和确认过期均在原 Store 写边界前拒绝")
    func selectionAndExpiryRejectionsAreWriteFree() throws {
        let fixture = makeDeletionFixture()
        defer { fixture.cleanup() }
        fixture.store.add(name: "待删任务", cronExpression: "0 9 * * *", command: "run")
        fixture.store.add(name: "其他任务", cronExpression: "0 10 * * *", command: "keep")
        let target = try #require(fixture.store.allTasks().first { $0.name == "待删任务" })
        let other = try #require(fixture.store.allTasks().first { $0.name == "其他任务" })
        let now = Date(timeIntervalSince1970: 1_788_800_000)
        let request = try #require(SchedulerTaskDeletionConsumer.request(for: target, now: now))
        let before = fixture.snapshot()

        #expect(SchedulerTaskDeletionConsumer.confirm(
            request,
            selectedTaskID: other.id,
            store: fixture.store,
            now: now
        ) == .rejected(.selectionChanged))
        #expect(fixture.snapshot() == before)

        #expect(SchedulerTaskDeletionConsumer.confirm(
            request,
            selectedTaskID: target.id,
            store: fixture.store,
            now: request.expiresAt
        ) == .rejected(.expired))
        #expect(fixture.snapshot() == before)
    }

    @Test("旧版本、已删除目标和重复确认都不产生新写入")
    func staleMissingAndDuplicateConfirmationsAreWriteFree() throws {
        let staleFixture = makeDeletionFixture()
        defer { staleFixture.cleanup() }
        staleFixture.store.add(name: "会变化", cronExpression: "0 9 * * *", command: "v1")
        let original = try #require(staleFixture.store.allTasks().first)
        let staleRequest = try #require(SchedulerTaskDeletionConsumer.request(for: original))
        var edited = original
        edited.command = "v2"
        #expect(staleFixture.store.update(edited, expectedVersion: original.version) == nil)
        let afterEdit = staleFixture.snapshot()

        #expect(SchedulerTaskDeletionConsumer.confirm(
            staleRequest,
            selectedTaskID: original.id,
            store: staleFixture.store
        ) == .rejected(.taskChanged))
        #expect(staleFixture.snapshot() == afterEdit)

        let duplicateFixture = makeDeletionFixture()
        defer { duplicateFixture.cleanup() }
        duplicateFixture.store.add(name: "只删一次", cronExpression: "0 11 * * *", command: "once")
        let target = try #require(duplicateFixture.store.allTasks().first)
        let request = try #require(SchedulerTaskDeletionConsumer.request(for: target))
        #expect(SchedulerTaskDeletionConsumer.confirm(
            request,
            selectedTaskID: target.id,
            store: duplicateFixture.store
        ) == .deleted)
        let afterDelete = duplicateFixture.snapshot()

        #expect(SchedulerTaskDeletionConsumer.confirm(
            request,
            selectedTaskID: target.id,
            store: duplicateFixture.store
        ) == .rejected(.missingOrDeleted))
        #expect(duplicateFixture.snapshot() == afterDelete)
        #expect(duplicateFixture.store.task(id: target.id)?.isDeleted == true)
        #expect(duplicateFixture.store.task(id: target.id)?.version == target.version + 1)
    }

    @Test("删除经原 Store 持久化 tombstone，并保留 occurrence 与其他任务")
    func deletionPersistsTombstoneAndOccurrenceOutcomesAcrossReopen() throws {
        let fixture = makeDeletionFixture()
        defer { fixture.cleanup() }
        fixture.store.add(
            name: "删除目标",
            cronExpression: "* * * * *",
            command: "delete-me",
            targetSessionID: UUID(),
            targetProjectID: "scheduler-delete",
            targetTurnID: 1
        )
        fixture.store.add(name: "保留目标", cronExpression: "* * * * *", command: "keep-me")
        let target = try #require(fixture.store.allTasks().first { $0.name == "删除目标" })
        let unaffected = try #require(fixture.store.allTasks().first { $0.name == "保留目标" })
        #expect(fixture.store.authorize(
            target.id,
            actorID: "scheduler-delete-test",
            scopeID: "scheduler-delete",
            policyRevision: "policy-v1"
        ))
        let pending = try #require(fixture.store.reserveOccurrence(
            taskID: target.id,
            at: Date(timeIntervalSince1970: 1_788_800_000),
            calendar: utcCalendar
        ))
        let running = try #require(fixture.store.reserveOccurrence(
            taskID: target.id,
            at: Date(timeIntervalSince1970: 1_788_800_060),
            calendar: utcCalendar
        ))
        #expect(fixture.store.compareAndSwapOccurrence(
            id: running.id,
            expected: .triggered,
            next: .authorized,
            expectedControlRevision: target.version
        ))
        #expect(fixture.store.compareAndSwapOccurrence(
            id: running.id,
            expected: .authorized,
            next: .admitted,
            expectedControlRevision: target.version
        ))
        #expect(fixture.store.compareAndSwapOccurrence(
            id: running.id,
            expected: .admitted,
            next: .dispatched,
            expectedControlRevision: target.version
        ))
        let leaseNow = Date(timeIntervalSince1970: 1_788_800_120)
        let leaseToken = try #require(fixture.store.claimLease(
            id: running.id,
            owner: "delete-owner",
            expectedControlRevision: target.version,
            now: leaseNow,
            ttl: 300
        ))
        #expect(fixture.store.heartbeat(
            id: running.id,
            owner: "delete-owner",
            token: leaseToken,
            now: leaseNow.addingTimeInterval(1),
            ttl: 300
        ))
        let unaffectedOccurrence = try #require(fixture.store.reserveOccurrence(
            taskID: unaffected.id,
            at: Date(timeIntervalSince1970: 1_788_800_180),
            calendar: utcCalendar
        ))
        let request = try #require(SchedulerTaskDeletionConsumer.request(for: target))

        #expect(SchedulerTaskDeletionConsumer.confirm(
            request,
            selectedTaskID: target.id,
            store: fixture.store
        ) == .deleted)

        let reopened = SchedulerTaskStore(
            defaults: fixture.defaults,
            occurrenceLedgerURL: fixture.ledgerURL
        )
        #expect(reopened.persistenceError == nil)
        let tombstone = try #require(reopened.task(id: target.id))
        #expect(tombstone.isDeleted)
        #expect(!tombstone.isEnabled)
        #expect(!tombstone.isAuthorized)
        #expect(tombstone.authorizationRevoked)
        #expect(tombstone.version == target.version + 1)
        #expect(reopened.occurrence(id: pending.id)?.state == .cancelled)
        #expect(reopened.occurrence(id: running.id)?.state == .unknown)
        #expect(reopened.occurrence(id: running.id)?.deliveryReceipt?.status == .unknown)
        #expect(reopened.occurrence(id: unaffectedOccurrence.id)?.state == .triggered)
        #expect(reopened.task(id: unaffected.id) == unaffected)
        #expect(reopened.allTasks().map(\.id) == [unaffected.id])
    }

    @Test("持久化失败使 Void 删除回滚且 consumer 不报告成功")
    func persistenceFailureRollsBackTaskAndReturnsFailure() throws {
        let fixture = makeDeletionFixture()
        defer { fixture.cleanup() }
        fixture.store.add(name: "回滚目标", cronExpression: "0 9 * * *", command: "rollback")
        let target = try #require(fixture.store.allTasks().first)
        let request = try #require(SchedulerTaskDeletionConsumer.request(for: target))
        let before = fixture.snapshot()
        try FileManager.default.createDirectory(at: fixture.ledgerURL, withIntermediateDirectories: false)

        #expect(SchedulerTaskDeletionConsumer.confirm(
            request,
            selectedTaskID: target.id,
            store: fixture.store
        ) == .rejected(.persistenceFailed))
        #expect(fixture.store.persistenceError == .ledgerWriteFailed(path: fixture.ledgerURL.path))
        #expect(fixture.store.task(id: target.id) == target)
        #expect(fixture.store.allTasks().map(\.id) == [target.id])
        #expect(fixture.store.occurrences == before.occurrences)
        #expect(fixture.store.occurrenceJournal == before.journal)
        #expect(fixture.defaults.data(forKey: "miniscanvas.scheduler.tasks.v1") == before.persistedTasks)
    }

    @Test("失败删除恢复原 JSON 字节格式或原键缺失，不重编码且不改邻接键")
    func persistenceFailurePreservesEncodedBeforeImageAndAbsence() throws {
        for originallyAbsent in [false, true] {
            let fixture = makeDeletionFixture()
            defer { fixture.cleanup() }
            fixture.store.add(name: "原字节回滚", cronExpression: "0 9 * * *", command: "rollback-bytes")
            let target = try #require(fixture.store.allTasks().first)
            let request = try #require(SchedulerTaskDeletionConsumer.request(for: target))
            let key = "miniscanvas.scheduler.tasks.v1"
            let encoded = try #require(fixture.defaults.data(forKey: key))
            // Valid JSON whitespace makes a re-encode observably different even
            // when an encoder happens to emit its object keys in the same order.
            let originalBytes = Data("\n ".utf8) + encoded + Data("\n".utf8)
            try #require(JSONDecoder().decode([SchedulerTask].self, from: originalBytes) == fixture.store.tasks)
            if originallyAbsent {
                fixture.defaults.removeObject(forKey: key)
            } else {
                fixture.defaults.set(originalBytes, forKey: key)
            }
            fixture.defaults.set("unchanged", forKey: "scheduler.rollback.unselected")
            let before = fixture.snapshot()
            try #require(before.tasks == [target] && !target.isDeleted)
            try #require(before.persistedTasks == (originallyAbsent ? nil : originalBytes))
            try FileManager.default.createDirectory(at: fixture.ledgerURL, withIntermediateDirectories: false)

            #expect(SchedulerTaskDeletionConsumer.confirm(request, selectedTaskID: target.id, store: fixture.store)
                    == .rejected(.persistenceFailed))
            #expect(fixture.store.persistenceError == .ledgerWriteFailed(path: fixture.ledgerURL.path))
            #expect(fixture.store.tasks == before.tasks)
            #expect(fixture.store.occurrences == before.occurrences)
            #expect(fixture.store.occurrenceJournal == before.journal)
            #expect(fixture.defaults.data(forKey: key) == before.persistedTasks)
            if originallyAbsent { #expect(fixture.defaults.object(forKey: key) == nil) }
            #expect(fixture.defaults.string(forKey: "scheduler.rollback.unselected") == "unchanged")
        }
    }

    @Test("既有持久化错误在调用删除前拒绝且保持全部状态")
    func existingPersistenceErrorRejectsWithoutNewWrite() throws {
        let fixture = makeDeletionFixture()
        defer { fixture.cleanup() }
        fixture.store.add(name: "错误前任务", cronExpression: "0 9 * * *", command: "keep")
        try Data("not-a-ledger".utf8).write(to: fixture.ledgerURL, options: .atomic)
        let blockedStore = SchedulerTaskStore(
            defaults: fixture.defaults,
            occurrenceLedgerURL: fixture.ledgerURL
        )
        let target = try #require(blockedStore.allTasks().first)
        let request = try #require(SchedulerTaskDeletionConsumer.request(for: target))
        let beforeTasks = blockedStore.tasks
        let beforeOccurrences = blockedStore.occurrences
        let beforeJournal = blockedStore.occurrenceJournal
        let beforeDefaults = fixture.defaults.data(forKey: "miniscanvas.scheduler.tasks.v1")
        let beforeFiles = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted()

        #expect(blockedStore.persistenceError != nil)
        #expect(SchedulerTaskDeletionConsumer.confirm(
            request,
            selectedTaskID: target.id,
            store: blockedStore
        ) == .rejected(.existingPersistenceError))
        #expect(blockedStore.tasks == beforeTasks)
        #expect(blockedStore.occurrences == beforeOccurrences)
        #expect(blockedStore.occurrenceJournal == beforeJournal)
        #expect(fixture.defaults.data(forKey: "miniscanvas.scheduler.tasks.v1") == beforeDefaults)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted() == beforeFiles)
    }

    @Test("原生 AX 删除入口的打开和取消无写，确认到达原 Store 删除边界")
    func nativeDeleteOpenCancelAndConfirmReachProductionConsumer() throws {
        let fixture = makeDeletionFixture()
        defer { fixture.cleanup() }
        fixture.store.add(name: "无授权也可删除", cronExpression: "0 9 * * *", command: "")
        let target = try #require(fixture.store.allTasks().first)
        let before = fixture.snapshot()
        let host = schedulerMakeHost(SchedulerControlSettingsView(store: fixture.store))
        defer { schedulerCloseHost(host) }
        let deleteID = "scheduler.task.delete.\(target.id.uuidString)"

        let openDelete = try #require(schedulerFindAX(host.window, identifier: deleteID))
        #expect(schedulerAXRole(openDelete) == .button)
        #expect(schedulerAXEnabled(openDelete))
        #expect(schedulerAXLabel(openDelete) == "删除定时任务 无授权也可删除")
        #expect(schedulerAXPress(openDelete))
        schedulerPumpAX(host)
        let confirmation = try #require(schedulerFindAX(
            host.window,
            identifier: "scheduler.delete.confirmation"
        ))
        #expect(schedulerAXLabel(confirmation)?.contains("无授权也可删除") == true)
        #expect(schedulerFindAX(host.window, identifier: "scheduler.preview.panel") == nil)
        #expect(fixture.snapshot() == before)

        let cancel = try #require(schedulerFindAX(host.window, identifier: "scheduler.delete.cancel"))
        #expect(schedulerAXRole(cancel) == .button)
        #expect(schedulerAXPress(cancel))
        schedulerPumpAX(host)
        #expect(schedulerFindAX(host.window, identifier: "scheduler.delete.confirmation") == nil)
        #expect(fixture.snapshot() == before)

        let reopenDelete = try #require(schedulerFindAX(host.window, identifier: deleteID))
        #expect(schedulerAXEnabled(reopenDelete))
        #expect(schedulerAXPress(reopenDelete))
        schedulerPumpAX(host)
        let confirm = try #require(schedulerFindAX(host.window, identifier: "scheduler.delete.confirm"))
        #expect(schedulerAXRole(confirm) == .button)
        #expect(schedulerAXLabel(confirm) == "确认删除定时任务 无授权也可删除")
        #expect(schedulerAXPress(confirm))
        schedulerPumpAX(host)

        #expect(fixture.store.task(id: target.id)?.isDeleted == true)
        #expect(fixture.store.task(id: target.id)?.version == target.version + 1)
        #expect(fixture.store.allTasks().isEmpty)
    }

    @Test("无执行预览时持久化失败仍通过原生 AX 显示且保留任务")
    func nativePersistenceFailureIsVisibleWithoutPreview() throws {
        let fixture = makeDeletionFixture()
        defer { fixture.cleanup() }
        fixture.store.add(name: "无预览失败任务", cronExpression: "0 9 * * *", command: "")
        let target = try #require(fixture.store.allTasks().first)
        try FileManager.default.createDirectory(at: fixture.ledgerURL, withIntermediateDirectories: false)
        let host = schedulerMakeHost(SchedulerControlSettingsView(store: fixture.store))
        defer { schedulerCloseHost(host) }

        let openDelete = try #require(schedulerFindAX(
            host.window,
            identifier: "scheduler.task.delete.\(target.id.uuidString)"
        ))
        #expect(schedulerAXPress(openDelete))
        schedulerPumpAX(host)
        let confirm = try #require(schedulerFindAX(host.window, identifier: "scheduler.delete.confirm"))
        #expect(schedulerAXPress(confirm))
        schedulerPumpAX(host)

        let feedback = try #require(schedulerFindAX(host.window, identifier: "scheduler.delete.feedback"))
        #expect(schedulerAXLabel(feedback)?.contains("持久化失败") == true)
        #expect(schedulerFindAX(host.window, identifier: "scheduler.preview.panel") == nil)
        #expect(fixture.store.task(id: target.id) == target)
        #expect(fixture.store.allTasks().map(\.id) == [target.id])
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

private func schedulerRegularFileData(at url: URL) -> Data? {
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
          !isDirectory.boolValue else { return nil }
    return try? Data(contentsOf: url)
}

@MainActor
private func schedulerMakeHost<V: View>(_ rootView: V) -> (window: NSWindow, view: NSView) {
    let hostLease = NativeTestHostLifecycle.begin("SchedulerDelete")
    // The production SettingsView gives its page a bounded proposal before
    // mounting SchedulerControlSettingsView. Preserve that contract here so
    // List materializes its task-row AX children instead of collapsing the
    // standalone host to its unconstrained intrinsic size.
    let controller = NSHostingController(
        rootView: AnyView(rootView.frame(width: 1_100, height: 760))
    )
    controller.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 760),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    NativeTestHostLifecycle.bind(hostLease, to: window)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    let view = controller.view
    view.frame = NSRect(x: 0, y: 0, width: 1_100, height: 760)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    window.setContentSize(NSSize(width: 1_100, height: 760))
    // 宿主轴的单变量修复（scheduler-f16-baseline-028 首错诊断）。R4..R11 原始
    // 日志一致显示：在纯 in-process NSAccessibility selector 遍历下，NSHostingView
    // 对任意产品形态都不 vend SwiftUI 可访问性子树 —— 本行 List 与 eager
    // ScrollView+VStack 首错逐字节相同（r11 raw :469/:515），同一 head 上另一产品
    // 视图的无条件根标识符 settings.surface 在 30 轮 readiness 轮询后同样
    // surfaceProjected=false（residual-043 raw），TaskCenter 窗口遍历 123 节点仅见
    // 窗口 chrome。仓库内唯一实测成功路径是
    // TypographyPackageFieldJourney.makeHostedProbePreparation/exposeOwnedWindow
    // （:3371-3521）：对自家 pid 做一次有界、只读的公共 AXUIElement 曝光读取后，
    // 同形状的本地遍历立即 vend 出 SwiftUI.AccessibilityNode
    // （exposureOrder=local-before>bounded-own-AX>local-after，
    // localBefore found=false → localAfter found=true，全程 isKey/isActive 均为
    // false，故不是激活/时序竞态）。此处仅为宿主补上该次曝光读取；断言、
    // schedulerFindAX 查询与产品可见性一律未改动，曝光失败时行为与改前一致。
    let ownerIdentifier = "scheduler-delete-native-host-" + UUID().uuidString
    window.setAccessibilityIdentifier(ownerIdentifier)
    schedulerPumpAX((window, view))
    let exposureStatus = schedulerExposeOwnedWindowForAccessibility(
        window, ownerIdentifier: ownerIdentifier
    )
    print("SCHEDULER_NATIVE_HOST_EXPOSURE \(exposureStatus)")
    NativeTestHostLifecycle.observe(window, phase: "sampled")
    return (window, view)
}

@MainActor
private func schedulerCloseHost(_ host: (window: NSWindow, view: NSView)) {
    host.window.orderOut(nil)
    host.window.contentViewController = nil
    host.window.close()
    NativeTestHostLifecycle.end(host.window)
}

@MainActor
private func schedulerExposeOwnedWindowForAccessibility(
    _ window: NSWindow, ownerIdentifier: String
) -> String {
    // 只读、有界、仅针对本进程自家 pid 的公共 AXUIElement 曝光：
    // app 元素 → kAXWindowsAttribute → 按窗口 accessibilityIdentifier 唯一匹配自家
    // 宿主 → 对其做一次 kAXChildrenAttribute 读取。仿照
    // TypographyPackageFieldJourney.exposeOwnedWindow（:3429-3521）的同款读取序。
    // 该读取永不向遍历提供替代节点、不放宽任何断言：若曝光失败，宿主行为与
    // 修复前逐字节一致（schedulerFindAX 仍返回 nil），不会把真实缺失洗绿。
    let application = AXUIElementCreateApplication(getpid())
    guard AXUIElementSetMessagingTimeout(application, 0.05) == .success else {
        return "status=APP_MESSAGING_TIMEOUT_UNSET"
    }
    var windowCount = 0
    guard AXUIElementGetAttributeValueCount(
        application, kAXWindowsAttribute as CFString, &windowCount
    ) == .success, (1...16).contains(windowCount) else {
        return "status=OWN_WINDOWS_UNREADABLE windowCount=\(windowCount)"
    }
    var rawWindows: CFArray?
    guard AXUIElementCopyAttributeValues(
        application, kAXWindowsAttribute as CFString, 0, windowCount, &rawWindows
    ) == .success, let windows = rawWindows as? [AXUIElement] else {
        return "status=OWN_WINDOWS_COPY_FAILED"
    }
    var owner: AXUIElement?
    var matches = 0
    for element in windows.prefix(16) {
        _ = AXUIElementSetMessagingTimeout(element, 0.05)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXIdentifierAttribute as CFString, &value
        ) == .success, (value as? String) == ownerIdentifier {
            matches += 1
            owner = element
        }
    }
    guard matches == 1, let owner else {
        return "status=OWNER_NOT_UNIQUE matches=\(matches) windows=\(windows.count)"
    }
    var childCount = 0
    guard AXUIElementGetAttributeValueCount(
        owner, kAXChildrenAttribute as CFString, &childCount
    ) == .success else {
        return "status=OWNER_CHILDREN_UNREADABLE ownerMatches=\(matches)"
    }
    if childCount > 0 {
        var children: CFArray?
        _ = AXUIElementCopyAttributeValues(
            owner, kAXChildrenAttribute as CFString, 0, min(childCount, 4), &children
        )
    }
    return "status=EXPOSED children=\(childCount) windows=\(windows.count)"
}

@MainActor
private func schedulerPumpAX(_ host: (window: NSWindow, view: NSView)) {
    for _ in 0..<6 {
        host.window.layoutIfNeeded()
        host.view.layoutSubtreeIfNeeded()
        host.view.display()
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }
}

@MainActor
private func schedulerFindAX(_ object: AnyObject, identifier: String) -> AnyObject? {
    var visited = Set<ObjectIdentifier>()
    if let local = schedulerFindAX(object, identifier: identifier, visited: &visited),
       schedulerAXRole(local) != nil {
        return local
    }
    // 宿主轴的第二处单变量修正（scheduler-f16-baseline-028 根因分诊）：
    // R18C raw :471-474 与 PKG raw/test-baseline-native-ax-probe :21-25 显示，
    // 同一形状的原生宿主里，连 TaskCenterObservationView.swift:665-676 /
    // ContentView.swift:1265-1279 已带 accessibilityElement(children:.ignore)+
    // isButton 配方的按钮，本地 selector 遍历读到的附件节点也一律 role=nil、
    // enabled=false、label=nil、press=false。仓库内唯一实测成功读取通道是
    // TypographyPackageFieldJourney 自家 pid 的有界公共 AXUIElement 通道
    // （NativeAccessibilityPackageAXProbe 的 search/control/press 同款读取序，
    // :2292-2418），那正是 VoiceOver 实际使用的通道。本地遍历先走自家
    // NSAccessibility 树（已实测能命中 accessibilityIdentifier），若命中节点
    // 无 role，再走同款公共有界遍历；两条通道都找不到才返回 nil。
    // 所有 #expect/#require 断言、identifier 与期望值一字未改，未放宽任何条件。
    return schedulerPublicFindAX(identifier)
}

@MainActor
private func schedulerPublicFindAX(_ identifier: String) -> AnyObject? {
    // 只读、有界、仅自家 pid：app → kAXWindowsAttribute → 深度≤24、节点≤2048 的
    // kAXChildrenAttribute 广度递归，按 kAXIdentifierAttribute 精确匹配。
    // 与 schedulerExposeOwnedWindowForAccessibility 同一超时与遍历纪律。
    let application = AXUIElementCreateApplication(getpid())
    _ = AXUIElementSetMessagingTimeout(application, 0.05)
    // gate2 诊断 :702:55 "cannot convert value of type 'CFArray?' to expected
    // argument type 'CFTypeRef?' (aka 'Optional<AnyObject>')"：
    // AXUIElementCopyAttributeValue 的出参是 CFTypeRef?，而 CFArray? 的 Wrapped
    // 与它不等，inout 指针类型必须逐字相同。这里把声明改为 API 声明的 CFTypeRef?；
    // 运行时写入的仍是同一个 CFArray 对象，下一行 `rawWindows as? [AXUIElement]`
    // 与同函数 :718-:721 早已编译通过的 `children: CFTypeRef?` → as? [AXUIElement]
    // 完全同形，nil/空数组分支的行为一字未改（不为消诊断而加 as! 或 unchecked 转换）。
    var rawWindows: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        application, kAXWindowsAttribute as CFString, &rawWindows
    ) == .success, let windows = rawWindows as? [AXUIElement] else {
        return nil
    }
    var visited = Set<CFHashCode>()
    var budget = 2048
    func walk(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        if budget <= 0 || depth > 24 { return nil }
        budget -= 1
        guard visited.insert(CFHash(element)).inserted else { return nil }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXIdentifierAttribute as CFString, &value
        ) == .success, (value as? String) == identifier {
            return element
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &children
        ) == .success, let kidList = children as? [AXUIElement] else {
            return nil
        }
        for kid in kidList {
            if let match = walk(kid, depth: depth + 1) { return match }
        }
        return nil
    }
    for window in windows.prefix(16) {
        if let match = walk(window, depth: 0) {
            return match as AnyObject
        }
    }
    return nil
}

@MainActor
private func schedulerFindAX(
    _ object: AnyObject,
    identifier: String,
    visited: inout Set<ObjectIdentifier>
) -> AnyObject? {
    guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
    if schedulerAXIdentifier(object) == identifier { return object }
    let ordered = schedulerRawAXChildren(
        of: object,
        attribute: .childrenInNavigationOrderAttribute
    )
    // SwiftUI/List can expose a non-empty navigation-order projection while
    // placing nested controls only in the ordinary children projection.
    // Traverse both projections; the visited set below removes duplicates.
    var children = ordered
    children.append(contentsOf: schedulerRawAXChildren(of: object, attribute: .children))
    if let view = object as? NSView { children += view.subviews }
    if let window = object as? NSWindow, let content = window.contentView {
        children.append(content.superview ?? content)
    }
    for child in schedulerFlattenAXChildren(children) {
        let childObject = child as AnyObject
        if let match = schedulerFindAX(
            childObject,
            identifier: identifier,
            visited: &visited
        ) {
            return match
        }
    }
    return nil
}

@MainActor
private func schedulerRawAXChildren(
    of object: AnyObject,
    attribute: NSAccessibility.Attribute
) -> [Any] {
    let unignored = NSAccessibility.unignoredChildrenForOnlyChild(from: object)
    let selectorName = attribute == .childrenInNavigationOrderAttribute
        ? "accessibilityChildrenInNavigationOrder"
        : "accessibilityChildren"
    // :788 的同款无守卫旧协议直发（r19c :57488 崩溃类的两个现场之一）改走
    // schedulerRawAXAttribute 的 responds(to:) 守卫通道：选择子存在时返回值
    // 与原先逐字相同，__NSCFType 不响应时返回 nil 走 else 分支落回
    // unignored 通道，不再 abort 进程。断言与期望值一字未改。
    guard let value = schedulerRawAXGetter(object, selectorName: selectorName)
        ?? schedulerRawAXAttribute(object, attribute) else {
        return unignored
    }
    if let values = value as? NSArray {
        let raw = values.map { $0 }
        return raw + NSAccessibility.unignoredChildren(from: raw) + unignored
    }
    return [value] + NSAccessibility.unignoredChildrenForOnlyChild(from: value) + unignored
}

private func schedulerFlattenAXChildren(_ children: [Any]) -> [Any] {
    children.flatMap { child in
        if let nested = child as? [Any] { return schedulerFlattenAXChildren(nested) }
        if let nested = child as? NSArray { return schedulerFlattenAXChildren(nested.map { $0 }) }
        return [child]
    }
}

@MainActor
private func schedulerRawAXGetter(_ object: AnyObject, selectorName: String) -> Any? {
    guard let object = object as? NSObject else { return nil }
    let selector = NSSelectorFromString(selectorName)
    guard object.responds(to: selector), let result = object.perform(selector) else { return nil }
    return result.takeUnretainedValue()
}

@MainActor
private func schedulerRawAXAttribute(
    _ object: AnyObject,
    _ attribute: NSAccessibility.Attribute
) -> Any? {
    // r19c 崩溃修复（scheduler-f16-baseline-028）：raw :57488/:57518 记录
    // '-[__NSCFType accessibilityAttributeValue:]: unrecognized selector' →
    // NSException → 整个 xctest 进程 abort。根因：Swift 把 CoreFoundation 不透明
    // 类型（公共通道装箱的 AXUIElement）桥接为 NSObject，`as? NSObject` 恒成功，
    // 但 __NSCFType 未实现旧非正式协议选择子 accessibilityAttributeValue:，
    // 无守卫直发即 doesNotRecognizeSelector:。这里采用本文件 schedulerRawAXGetter
    // 已验证的守卫写法（guard object.responds(to: selector) 后才发送）：
    // 响应则原样发送、取原值；不响应则返回 nil，等于「选择子不存在但安全」时
    // 本应得到的回退值，调用方照常落回另一通道。断言与期望值一字未改。
    guard let object = object as? NSObject,
          object.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) else {
        return nil
    }
    return UF03LegacyAttribute(object, attribute)
}

@MainActor
private func schedulerPublicAXElement(_ object: AnyObject) -> AXUIElement? {
    // gate2 诊断 :819:32 与 :880:29 同一条 error "conditional downcast to CoreFoundation
    // type 'AXUIElement' will always succeed"，其 note 直接给出修复方向：
    // "did you mean to explicitly compare the CFTypeIDs of 'object' and 'AXUIElement'?"
    // 原 `object as? AXUIElement` 永远成功，喂给它的 guard/if-let 是空判：本地通道
    // （schedulerFindAX(_:identifier:visited:) 走 NSView 树返回的 NSView/NSObject）
    // 也会被当作 AXUIElement 送进公共 AX API。这里换成真正可失败的判别：
    // CFGetTypeID 对非 CoreFoundation 对象返回 0，只有公共通道
    // （schedulerPublicFindAX 把 AXUIElement 装箱成 AnyObject 返回）才通过。
    // typeID 判定 + unsafeDowncast 是本仓库唯一实测可用的同款写法
    // （NativeAccessibilityPackageAXProbe.decodedElements，
    // TypographyPackageFieldJourney.swift:2464-2468），不是用来消诊断的裸强转：
    // 转换前置了可失败的运行时类型闸，判别失败即返回 nil，
    // 调用方按原设计落回本地 NSAccessibility 通道。断言与期望值一字未改。
    guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(object, to: AXUIElement.self)
}

@MainActor
private func schedulerPublicAttribute(_ object: AnyObject, _ name: CFString) -> CFTypeRef? {
    // schedulerPublicFindAX 返回的是公共通道的 AXUIElement；与
    // NativeAccessibilityPackageAXProbe.readAttribute 同款有界自家 pid 读取。
    guard let element = schedulerPublicAXElement(object) else { return nil }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value
}

private func schedulerPublicBool(_ value: CFTypeRef?) -> Bool? {
    // 与 NativeAccessibilityPackageAXProbe.decodedBool 同款：先按 CFBoolean
    // typeID 判定，避免依赖 AnyObject→Bool 隐式桥接。
    guard let value else { return nil }
    if CFGetTypeID(value) == CFBooleanGetTypeID() {
        return CFBooleanGetValue((value as! CFBoolean))
    }
    if let number = value as? NSNumber { return number.boolValue }
    return value as? Bool
}

@MainActor
private func schedulerAXIdentifier(_ object: AnyObject) -> String? {
    if let value = schedulerPublicAttribute(object, kAXIdentifierAttribute as CFString) as? String,
       !value.isEmpty { return value }
    if let value = schedulerRawAXGetter(object, selectorName: "accessibilityIdentifier") as? String,
       !value.isEmpty { return value }
    if let value = schedulerRawAXAttribute(object, .identifier) as? String,
       !value.isEmpty { return value }
    return (object as? NSAccessibilityProtocol)?.accessibilityIdentifier()
}

@MainActor
private func schedulerAXRole(_ object: AnyObject) -> NSAccessibility.Role? {
    if let value = schedulerPublicAttribute(object, kAXRoleAttribute as CFString) as? String {
        return NSAccessibility.Role(rawValue: value)
    }
    return (object as? NSAccessibilityProtocol)?.accessibilityRole()
        ?? schedulerRawAXAttribute(object, .role) as? NSAccessibility.Role
}

@MainActor
private func schedulerAXEnabled(_ object: AnyObject) -> Bool {
    if let value = schedulerPublicAttribute(object, kAXEnabledAttribute as CFString) {
        return schedulerPublicBool(value) ?? false
    }
    return (object as? NSAccessibilityProtocol)?.isAccessibilityEnabled()
        ?? schedulerRawAXAttribute(object, .enabled) as? Bool
        ?? false
}

@MainActor
private func schedulerAXLabel(_ object: AnyObject) -> String? {
    if let value = schedulerPublicAttribute(object, kAXDescriptionAttribute as CFString) as? String {
        return value
    }
    if let value = schedulerPublicAttribute(object, kAXTitleAttribute as CFString) as? String {
        return value
    }
    return (object as? NSAccessibilityProtocol)?.accessibilityLabel()
        ?? schedulerRawAXAttribute(object, .description) as? String
}

@MainActor
private func schedulerAXPress(_ object: AnyObject) -> Bool {
    if let element = schedulerPublicAXElement(object) {
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }
    if let accessibilityObject = object as? NSAccessibilityProtocol,
       accessibilityObject.accessibilityPerformPress() {
        return true
    }
    guard let object = object as? NSObject,
          (object.perform(NSSelectorFromString("accessibilityActionNames"))?.takeUnretainedValue() as? [String])?.contains(NSAccessibility.Action.press.rawValue) == true else { return false }
    _ = object.perform(NSSelectorFromString("accessibilityPerformAction:"), with: NSAccessibility.Action.press.rawValue)
    return true
}
