import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class SchedulerRuntimeRequestCapture: @unchecked Sendable {
    var requests: [SchedulerSubmissionRequest] = []
}

@MainActor
private final class SchedulerRuntimeEffectProbe {
    private(set) var contexts: [SchedulerExecutionContext] = []
    private var releaseContinuation: CheckedContinuation<SchedulerEffectOutcome, Error>?

    enum StartError: Error {
        case timedOut
    }

    func submit(_ context: SchedulerExecutionContext) async throws -> SchedulerEffectOutcome {
        contexts.append(context)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SchedulerEffectOutcome, Error>) in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted(timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while contexts.isEmpty {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw StartError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func release(status: SchedulerDeliveryReceipt.Status) {
        guard let releaseContinuation else { return }
        self.releaseContinuation = nil
        releaseContinuation.resume(returning: SchedulerEffectOutcome(status: status))
    }
}

@Suite("P3 scheduler runtime and event consumer")
@MainActor
struct SchedulerRuntimeConsumerTests {

    private func makeStore() -> (SchedulerTaskStore, () -> Void) {
        let suite = "scheduler-runtime-consumer-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-runtime-consumer-\(UUID().uuidString)", isDirectory: true)
        let ledger = directory.appendingPathComponent("occurrences.json")
        let store = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        return (store, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    private func addAuthorizedTask(to store: SchedulerTaskStore) -> SchedulerTask {
        store.add(
            name: "运行时任务",
            cronExpression: "* * * * *",
            command: "不应出现在 slash read model",
            targetSessionID: UUID(),
            targetProjectID: "runtime-project",
            targetTurnID: 7
        )
        let task = store.allTasks()[0]
        #expect(store.authorize(task.id))
        return task
    }

    private func makeReopenableStore() -> (SchedulerTaskStore, UserDefaults, URL, () -> Void) {
        let suite = "scheduler-edit-consumer-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-edit-consumer-\(UUID().uuidString)", isDirectory: true)
        let ledger = directory.appendingPathComponent("occurrences.json")
        let store = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        return (store, defaults, ledger, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    @Test func requestBoundaryCarriesOneStableExecutionIdentity() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let task = addAuthorizedTask(to: store)
        let capture = SchedulerRuntimeRequestCapture()
        let runtime = SchedulerTaskRuntime(store: store, submitRequest: { request in
            capture.requests.append(request)
        })
        let date = Date(timeIntervalSince1970: 1_756_650_000)

        runtime.pollNow(at: date)
        runtime.pollNow(at: date.addingTimeInterval(20))

        #expect(capture.requests.count == 1)
        let request = capture.requests[0]
        #expect(request.taskID == task.id)
        #expect(request.sourceTaskID == task.id)
        #expect(request.command == "不应出现在 slash read model")
        #expect(request.hasValidTarget)
        #expect(store.executionIdentity(id: request.occurrenceID)?.effectID == request.effectID)
        #expect(store.occurrence(id: request.occurrenceID)?.state == .unknown)
    }

    @Test func stoppedInFlightEffectRemainsUnknownUntilDurableTargetFactReconciles() async throws {
        let (store, defaults, ledger, cleanup) = makeReopenableStore()
        defer { cleanup() }
        let task = addAuthorizedTask(to: store)
        let targetID = try #require(task.targetSessionID)
        let targetStore = SessionStore(directory: ledger.deletingLastPathComponent()
            .appendingPathComponent("target", isDirectory: true))
        let target = try targetStore.createSession(id: targetID.uuidString, projectID: "runtime-project")
        let date = Date(timeIntervalSince1970: 1_756_650_000)
        let probe = SchedulerRuntimeEffectProbe()
        defer { probe.release(status: .unknown) }
        let runtime = SchedulerTaskRuntime(store: store, now: { date },
            submitEffect: { context in try await probe.submit(context) })

        runtime.pollNow(at: date)
        try await probe.waitUntilStarted()
        let context = try #require(probe.contexts.first)
        let execution = try #require(store.beginExecutionIdentity(context.request,
            owner: context.owner, token: context.token, minimumTurn: 8, now: date))
        runtime.pollNow(at: date.addingTimeInterval(20))
        #expect(probe.contexts.count == 1, "normal running must not start a second effect")

        // The target may commit before a stopped task can persist its receipt.
        // Cancellation cannot prove that no provider/target effect occurred.
        runtime.stop()
        probe.release(status: .delivered)
        for _ in 0..<100 {
            if store.occurrence(id: context.request.occurrenceID)?.state == .unknown { break }
            await Task.yield()
        }
        let uncertain = try #require(store.occurrence(id: context.request.occurrenceID))
        #expect(uncertain.state == .unknown)
        #expect(uncertain.deliveryReceipt?.status == .unknown)
        #expect(uncertain.submissionReceipt?.request == context.request)
        #expect(uncertain.executionTurnID == execution.turn)
        #expect(uncertain.executionMessageID == execution.messageID)

        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(reopened.persistenceError == nil)
        let restartProbe = SchedulerRuntimeEffectProbe()
        let reader = SchedulerTaskRuntime(store: reopened, now: { date },
            targetDeliveryResolver: { row in
                targetStore.loadSession(id: targetID.uuidString)?.scheduledTranscriptDeliveries.first {
                    $0.occurrenceID == row.id && $0.effectID == row.effectID
                }
            }, submitEffect: { context in try await restartProbe.submit(context) })
        reader.pollNow(at: date)
        #expect(restartProbe.contexts.isEmpty, "UNKNOWN must not redispatch after reopen")
        #expect(reader.queryTargetDelivery(id: uncertain.id) == .noMatchingFact(occurrence: uncertain))
        #expect(!reader.reconcileUnknownOccurrence(id: uncertain.id, now: date))

        let fact = ScheduledTranscriptDelivery(occurrenceID: uncertain.id,
            effectID: uncertain.effectID, taskID: uncertain.taskID,
            taskVersion: uncertain.taskVersion, executionTurnID: execution.turn,
            executionMessageID: execution.messageID)
        _ = try targetStore.compareAndCommitTranscript(sessionID: target.id,
            projectID: "runtime-project", expectedRevision: target.transcriptRevision,
            expectedMessages: target.messages,
            replacementMessages: [LLMMessage(role: .user, content: "synthetic scheduled input"),
                                  LLMMessage(role: .assistant, content: "synthetic reply")],
            scheduledDelivery: fact)
        #expect(reader.queryTargetDelivery(id: uncertain.id)
            == .deliveryObserved(occurrence: uncertain, targetFact: fact))
        #expect(reader.reconcileUnknownOccurrence(id: uncertain.id, now: date.addingTimeInterval(1)))
        let settled = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(settled.occurrence(id: uncertain.id)?.state == .succeeded)
        #expect(settled.occurrence(id: uncertain.id)?.submissionReceipt?.request == context.request)
        #expect(settled.occurrences.count == 1)
        #expect(restartProbe.contexts.isEmpty)
    }

    @Test func confirmedZoneSurvivesReopenAndDifferentDeviceCalendar() throws {
        let (store, defaults, ledger, cleanup) = makeReopenableStore()
        defer { cleanup() }
        #expect(store.add(name: "UTC morning", cronExpression: "0 9 * * *",
            command: "bound-zone", targetSessionID: UUID(),
            targetProjectID: "runtime-project", targetTurnID: 3) == nil)
        let task = try #require(store.allTasks().first)
        let formatter = ISO8601DateFormatter()
        let previewAt = try #require(formatter.date(from: "2026-10-01T08:59:00Z"))
        let dueAt = try #require(formatter.date(from: "2026-10-01T09:00:00Z"))
        let deviceLocalNine = try #require(formatter.date(from: "2026-10-01T13:00:00Z"))
        let preview = try #require(store.preview(taskID: task.id, now: previewAt,
            timeZone: TimeZone(identifier: "UTC")!))
        #expect(preview.predictedTriggers.first == dueAt)
        #expect(store.confirmPreview(preview, actorID: "user", scopeID: "runtime-project",
            policyRevision: "scheduler-policy-v1", now: previewAt))

        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(reopened.task(id: task.id)?.timeZoneIdentifier == preview.timeZoneIdentifier)
        #expect(reopened.preview(taskID: task.id, now: previewAt)?.timeZoneIdentifier
            == preview.timeZoneIdentifier)
        var changedDeviceCalendar = Calendar(identifier: .gregorian)
        changedDeviceCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        let capture = SchedulerRuntimeRequestCapture()
        let runtime = SchedulerTaskRuntime(store: reopened, submitRequest: { request in
            capture.requests.append(request)
        })
        runtime.pollNow(at: dueAt, calendar: changedDeviceCalendar)
        runtime.pollNow(at: dueAt.addingTimeInterval(20), calendar: changedDeviceCalendar)
        #expect(capture.requests.count == 1)
        runtime.pollNow(at: deviceLocalNine, calendar: changedDeviceCalendar)
        #expect(capture.requests.count == 1)
        #expect(reopened.occurrences.filter { $0.taskID == task.id }.count == 1)
    }

    @Test func ambiguousDSTMinuteNeverCreatesAProductionOccurrence() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        #expect(store.add(name: "fold", cronExpression: "30 1 * * *",
            command: "must-not-run", targetSessionID: UUID(),
            targetProjectID: "runtime-project", targetTurnID: 4) == nil)
        var task = try #require(store.allTasks().first)
        task.timeZoneIdentifier = "America/New_York"
        #expect(store.update(task, expectedVersion: task.version) == nil)
        let formatter = ISO8601DateFormatter()
        let authorizationDate = try #require(formatter.date(from: "2026-10-01T00:00:00Z"))
        #expect(store.authorize(task.id, now: authorizationDate))

        let firstFold = try #require(formatter.date(from: "2026-11-01T05:30:00Z"))
        let secondFold = try #require(formatter.date(from: "2026-11-01T06:30:00Z"))
        let capture = SchedulerRuntimeRequestCapture()
        let runtime = SchedulerTaskRuntime(store: store, submitRequest: { capture.requests.append($0) })
        runtime.pollNow(at: firstFold)
        runtime.pollNow(at: secondFold)
        #expect(capture.requests.isEmpty)
        #expect(store.occurrences.isEmpty)
    }

    @Test func failedDeliveryIsTerminalAndDoesNotRedispatchOnReopen() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let task = addAuthorizedTask(to: store)
        let date = Date(timeIntervalSince1970: 1_756_650_000)
        let runtime = SchedulerTaskRuntime(store: store, submitOccurrenceResult: { request in
            #expect(request.taskID == task.id)
            return .failed
        })

        runtime.pollNow(at: date)
        let firstRows = store.occurrences.filter { $0.taskID == task.id }
        #expect(firstRows.count == 1)
        #expect(firstRows.first?.state == .failed)
        runtime.pollNow(at: date.addingTimeInterval(60))
        #expect(store.occurrences.filter { $0.taskID == task.id }.count == 2)
    }

    @Test func explicitRuntimeRecoveryReconcilesAndRetriesOnlyWithPersistedProof() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let task = addAuthorizedTask(to: store)
        let date = Date(timeIntervalSince1970: 1_756_650_000)
        let runtime = SchedulerTaskRuntime(store: store, submitCommand: { _ in })

        runtime.pollNow(at: date)
        guard let original = store.occurrences.first(where: { $0.taskID == task.id }) else {
            Issue.record("应存在已记录 UNKNOWN 的 occurrence")
            return
        }
        #expect(store.occurrence(id: original.id)?.state == .unknown)
        #expect(runtime.retryReconciledOccurrence(
            id: original.id,
            expectedControlRevision: original.controlRevision,
            proofToken: "not-persisted"
        ) == nil)

        #expect(runtime.reconcileUnknownOccurrence(id: original.id, now: date.addingTimeInterval(1)))
        guard let reconciled = store.occurrence(id: original.id),
              let proof = reconciled.reconciliationProof else {
            Issue.record("reconcile 必须持久化 proof")
            return
        }
        let retry = runtime.retryReconciledOccurrence(
            id: original.id,
            expectedControlRevision: reconciled.controlRevision,
            proofToken: proof,
            now: date.addingTimeInterval(2)
        )
        #expect(retry?.retryOfOccurrenceID == original.id)
        #expect(store.occurrence(id: original.id)?.state == .retryRequested)
        #expect(store.occurrences.filter { $0.taskID == task.id }.count == 2)
    }

    @Test func schedulerSlashReadIsRedactedAndActionable() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let task = addAuthorizedTask(to: store)
        let date = Date(timeIntervalSince1970: 1_756_650_000)
        #expect(store.revokeAuthorization(task.id))
        SchedulerTaskRuntime(store: store, submitOccurrenceResult: { _ in .delivered })
            .pollNow(at: date)

        let observation = SchedulerSlashObservation.capture(from: store)
        let adapter = TaskCenterSlashCommandAdapter(schedulerObservation: { observation })
        #expect(TaskCenterSlashCommandAdapter.handles("/scheduler"))
        let output = adapter.execute("/scheduler")
        #expect(output.contains("scheduler_observation"))
        #expect(output.contains("不应出现在 slash read model") == false)
        #expect(output.contains("waitingApproval") == true)
        #expect(output.contains("approve_or_cancel") == true)
        #expect(output.contains("等待授权") == true)
        #expect(output.contains("请授权或取消") == true)
        #expect(output.contains("requires_user_action") == true)
        #expect(adapter.execute("/scheduler status=running").contains("parameters_not_allowed"))
    }

    @Test func legacyTurnMeaningRequiresExplicitNewAnchorConfirmation() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let id = UUID()
        #expect(store.add(name: "legacy", cronExpression: "* * * * *", command: "prompt",
            targetSessionID: id, targetProjectID: "project", targetTurnID: 1) == nil)
        let initial = try #require(store.allTasks().first)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(initial)) as? [String: Any])
        object.removeValue(forKey: "sourceAnchorVersion")
        object.removeValue(forKey: "sourceAnchorDigest")
        let legacy = try JSONDecoder().decode(SchedulerTask.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.sourceAnchorVersion == 0)
        #expect(store.update(legacy, expectedVersion: initial.version) == nil)
        #expect(!store.authorize(initial.id))
        var preview = try #require(store.preview(taskID: initial.id))
        #expect(!store.confirmPreview(preview, actorID: "user", scopeID: "project", policyRevision: "policy"))
        let digest = try #require(SchedulerSourceAnchor.digest(sessionID: id.uuidString, projectID: "project",
            userOrdinal: 1, messages: [LLMMessage(role: .user, content: "source")]))
        preview.observedSourceAnchorDigest = digest
        preview.observedPolicyRevision = "policy"
        #expect(!store.confirmPreview(preview, actorID: "user", scopeID: "project", policyRevision: "policy",
            sourceAnchorConfirmed: true, currentSourceAnchorDigest: String(repeating: "0", count: 64), currentPolicyRevision: "policy"))
        #expect(store.confirmPreview(preview, actorID: "user", scopeID: "project", policyRevision: "policy",
            sourceAnchorConfirmed: true, currentSourceAnchorDigest: digest, currentPolicyRevision: "policy"))
        let confirmed = try #require(store.task(id: initial.id))
        #expect(confirmed.sourceAnchorVersion == 2)
        #expect(confirmed.sourceAnchorDigest == digest)
        #expect(confirmed.version > legacy.version)
        #expect(try JSONDecoder().decode(SchedulerTask.self, from: JSONEncoder().encode(confirmed)) == confirmed)
    }

    @Test func canonicalAnchorBindsOrdinalPrefixAndOwnerWhilePreservingAppend() throws {
        let repeated = [LLMMessage(role: .user, content: "same"), LLMMessage(role: .assistant, content: "context"),
                        LLMMessage(role: .user, content: "same")]
        let first = try #require(SchedulerSourceAnchor.digest(sessionID: "session", projectID: "project", userOrdinal: 1, messages: repeated))
        let second = try #require(SchedulerSourceAnchor.digest(sessionID: "session", projectID: "project", userOrdinal: 2, messages: repeated))
        #expect(first != second)
        #expect(SchedulerSourceAnchor.digest(sessionID: "session", projectID: "project", userOrdinal: 2,
            messages: repeated + [LLMMessage(role: .assistant, content: "appended")]) == second)
        #expect(SchedulerSourceAnchor.digest(sessionID: "other", projectID: "project", userOrdinal: 2, messages: repeated) != second)
        #expect(SchedulerSourceAnchor.digest(sessionID: "session", projectID: "other", userOrdinal: 2, messages: repeated) != second)
        #expect(SchedulerSourceAnchor.digest(sessionID: "session", projectID: "project", userOrdinal: 2,
            messages: Array(repeated.dropFirst())) == nil)
        let changed = [repeated[0], LLMMessage(role: .assistant, content: "changed context"), repeated[2]]
        #expect(SchedulerSourceAnchor.digest(sessionID: "session", projectID: "project", userOrdinal: 2, messages: changed) != second)
    }


    @Test func disabledQueuedHistoryCannotReenterAfterReopenOrReenable() throws {
        let suite = "scheduler-disabled-reopen-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-disabled-reopen-\(UUID().uuidString)", isDirectory: true)
        let ledger = directory.appendingPathComponent("occurrences.json")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let store = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        let task = addAuthorizedTask(to: store)
        let date = Date(timeIntervalSince1970: 1_756_650_000)
        let queued = try #require(store.reserveOccurrence(taskID: task.id, at: date))
        #expect(queued.state == .triggered)

        store.setEnabled(task.id, enabled: false)
        #expect(store.task(id: task.id)?.isEnabled == false)
        #expect(store.occurrence(id: queued.id)?.state == .cancelled)
        #expect(store.resumableOccurrences().isEmpty)
        #expect(store.reserveOccurrence(taskID: task.id, at: date.addingTimeInterval(60)) == nil)

        let sameProcessCapture = SchedulerRuntimeRequestCapture()
        SchedulerTaskRuntime(store: store, submitRequest: { request in
            sameProcessCapture.requests.append(request)
        }).pollNow(at: date.addingTimeInterval(60))
        #expect(sameProcessCapture.requests.isEmpty)

        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        let capture = SchedulerRuntimeRequestCapture()
        let runtime = SchedulerTaskRuntime(store: reopened, submitRequest: { request in
            capture.requests.append(request)
        })
        runtime.pollNow(at: date.addingTimeInterval(60))
        #expect(capture.requests.isEmpty)
        #expect(reopened.occurrence(id: queued.id)?.state == .cancelled)
        #expect(reopened.resumableOccurrences().isEmpty)

        reopened.setEnabled(task.id, enabled: true)
        runtime.pollNow(at: date)
        #expect(capture.requests.isEmpty)
        runtime.pollNow(at: date.addingTimeInterval(60))
        runtime.pollNow(at: date.addingTimeInterval(80))

        #expect(capture.requests.count == 1)
        #expect(capture.requests[0].taskID == task.id)
        #expect(capture.requests[0].occurrenceID != queued.id)
        #expect(reopened.occurrences.filter { $0.taskID == task.id }.count == 2)
        #expect(reopened.occurrence(id: queued.id)?.state == .cancelled)
    }

    @Test func deletedQueuedHistoryCannotReenterAfterReopen() throws {
        let suite = "scheduler-deleted-reopen-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-deleted-reopen-\(UUID().uuidString)", isDirectory: true)
        let ledger = directory.appendingPathComponent("occurrences.json")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let store = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        store.add(
            name: "删除后不重放",
            cronExpression: "* * * * *",
            command: "deleted command",
            targetSessionID: UUID(),
            targetProjectID: "scheduler-delete-reopen",
            targetTurnID: 1
        )
        let task = try #require(store.allTasks().first)
        #expect(store.authorize(task.id))
        let date = Date(timeIntervalSince1970: 1_756_650_000)
        let queued = try #require(store.reserveOccurrence(taskID: task.id, at: date))
        let request = try #require(SchedulerTaskDeletionConsumer.request(for: task, now: date))
        #expect(SchedulerTaskDeletionConsumer.confirm(
            request,
            selectedTaskID: task.id,
            store: store,
            now: date
        ) == .deleted)
        #expect(store.occurrence(id: queued.id)?.state == .cancelled)

        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        let capture = SchedulerRuntimeRequestCapture()
        let runtime = SchedulerTaskRuntime(store: reopened, submitRequest: { submission in
            capture.requests.append(submission)
        })
        runtime.pollNow(at: date.addingTimeInterval(60))

        #expect(capture.requests.isEmpty)
        #expect(reopened.task(id: task.id)?.isDeleted == true)
        #expect(reopened.occurrence(id: queued.id)?.state == .cancelled)
        #expect(reopened.resumableOccurrences().isEmpty)
    }

    @Test func pausedReconciledOccurrenceCannotBeRetried() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let task = addAuthorizedTask(to: store)
        let date = Date(timeIntervalSince1970: 1_756_650_000)
        let runtime = SchedulerTaskRuntime(store: store, submitCommand: { _ in })

        runtime.pollNow(at: date)
        let original = try #require(store.occurrences.first(where: { $0.taskID == task.id }))
        #expect(original.state == .unknown)
        #expect(runtime.reconcileUnknownOccurrence(id: original.id, now: date.addingTimeInterval(1)))
        let reconciled = try #require(store.occurrence(id: original.id))
        let proof = try #require(reconciled.reconciliationProof)
        store.setEnabled(task.id, enabled: false)
        let beforeCount = store.occurrences.count

        #expect(runtime.retryReconciledOccurrence(
            id: original.id,
            expectedControlRevision: reconciled.controlRevision,
            proofToken: proof,
            now: date.addingTimeInterval(2)
        ) == nil)
        #expect(store.occurrences.count == beforeCount)
    }

    @Test func pausingTaskLeavesRunningEffectCurrentUntilCompletion() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.add(
            name: "停用不杀运行中",
            cronExpression: "* * * * *",
            command: "running command",
            targetSessionID: UUID(),
            targetProjectID: "scheduler-running",
            targetTurnID: 1
        )
        var task = try #require(store.allTasks().first)
        task.sourceAnchorDigest = String(repeating: "a", count: 64)
        #expect(store.update(task, expectedVersion: task.version) == nil)
        let currentTask = try #require(store.task(id: task.id))
        #expect(store.authorize(currentTask.id))

        let date = Date(timeIntervalSince1970: 1_756_650_000)
        let queued = try #require(store.reserveOccurrence(taskID: currentTask.id, at: date))
        #expect(store.compareAndSwapOccurrence(
            id: queued.id,
            expected: .triggered,
            next: .authorized,
            expectedControlRevision: queued.controlRevision,
            now: date
        ))
        #expect(store.compareAndSwapOccurrence(
            id: queued.id,
            expected: .authorized,
            next: .admitted,
            expectedControlRevision: queued.controlRevision,
            now: date
        ))
        #expect(store.compareAndSwapOccurrence(
            id: queued.id,
            expected: .admitted,
            next: .dispatched,
            expectedControlRevision: queued.controlRevision,
            now: date
        ))
        let token = try #require(store.claimLease(
            id: queued.id,
            owner: "scheduler-runtime",
            expectedControlRevision: queued.controlRevision,
            now: date
        ))
        #expect(store.heartbeat(
            id: queued.id,
            owner: "scheduler-runtime",
            token: token,
            now: date.addingTimeInterval(1)
        ))
        let running = try #require(store.occurrence(id: queued.id))
        let request = SchedulerSubmissionRequest(
            occurrenceID: running.id,
            effectID: running.effectID,
            taskID: currentTask.id,
            taskVersion: running.taskVersion,
            idempotencyKey: running.idempotencyKey,
            command: running.command,
            targetSessionID: running.targetSessionID,
            targetProjectID: running.targetProjectID,
            targetTurnID: running.targetTurnID,
            sourceTaskID: currentTask.id
        )

        store.setEnabled(currentTask.id, enabled: false)
        #expect(store.task(id: currentTask.id)?.isEnabled == false)
        #expect(store.occurrence(id: running.id)?.state == .running)
        #expect(store.isSubmissionCurrent(
            request,
            owner: "scheduler-runtime",
            token: token,
            now: date.addingTimeInterval(2)
        ))
        #expect(store.recordDelivery(
            id: running.id,
            owner: "scheduler-runtime",
            token: token,
            status: .delivered,
            now: date.addingTimeInterval(2),
            expectedTaskVersion: running.taskVersion,
            expectedControlRevision: running.controlRevision
        ))
        #expect(store.occurrence(id: running.id)?.state == .succeeded)
    }

    @Test func editedQueuedOccurrenceRunsPinnedOnceAndNewVersionDispatchesOnce() throws {
        let (store, defaults, ledger, cleanup) = makeReopenableStore()
        defer { cleanup() }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let oldDate = Date(timeIntervalSince1970: 1_756_650_000)
        let oldSession = UUID()
        let newSession = UUID()

        #expect(store.add(
            name: "可编辑计划",
            cronExpression: "* * * * *",
            command: "old-command",
            targetSessionID: oldSession,
            targetProjectID: "old-project",
            targetTurnID: 7
        ) == nil)
        guard let originalTask = store.allTasks().first else {
            Issue.record("编辑回归必须有初始计划")
            return
        }
        #expect(store.authorize(
            originalTask.id,
            actorID: "actor-v1",
            scopeID: "scope-v1",
            policyRevision: "policy-v1"
        ))
        guard let oldOccurrence = store.reserveOccurrence(
            taskID: originalTask.id,
            at: oldDate,
            calendar: calendar
        ) else {
            Issue.record("编辑回归必须先持久化一个 queued occurrence")
            return
        }

        var edited = originalTask
        edited.cronExpression = "21 * * * *"
        edited.command = "new-command"
        edited.targetSessionID = newSession
        edited.targetProjectID = "new-project"
        edited.targetTurnID = 8
        edited.authorizationPolicyRevision = "policy-v2"
        #expect(store.update(edited, expectedVersion: originalTask.version) == nil)
        #expect(store.update(edited, expectedVersion: originalTask.version) != nil)

        guard let updatedTask = store.task(id: originalTask.id) else {
            Issue.record("编辑后必须能读取新版本计划")
            return
        }
        #expect(updatedTask.version == originalTask.version + 1)
        #expect(updatedTask.cronExpression == "21 * * * *")
        #expect(updatedTask.authorizationPolicyRevision == "policy-v2")
        #expect(!updatedTask.isAuthorized)

        let beforeReopenCapture = SchedulerRuntimeRequestCapture()
        SchedulerTaskRuntime(store: store, submitOccurrenceResult: { request in
            beforeReopenCapture.requests.append(request)
            return .delivered
        }).pollNow(at: oldDate, calendar: calendar)
        let pinnedRequest = try #require(beforeReopenCapture.requests.first)
        #expect(beforeReopenCapture.requests.count == 1)
        #expect(pinnedRequest.occurrenceID == oldOccurrence.id)
        #expect(pinnedRequest.taskVersion == originalTask.version)
        #expect(pinnedRequest.command == "old-command")
        #expect(pinnedRequest.targetSessionID == oldSession)
        #expect(pinnedRequest.targetProjectID == "old-project")
        #expect(pinnedRequest.targetTurnID == 7)
        let canonicalEncoder = JSONEncoder()
        canonicalEncoder.outputFormatting = [.sortedKeys]
        let pinnedReceipt = try #require(store.occurrence(id: oldOccurrence.id)?.submissionReceipt)
        let pinnedReceiptBytes = try canonicalEncoder.encode(pinnedReceipt)
        let pinnedJournalBytes = try canonicalEncoder.encode(
            store.occurrenceJournal.filter { $0.occurrenceID == oldOccurrence.id }
        )

        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        let capture = SchedulerRuntimeRequestCapture()
        let runtime = SchedulerTaskRuntime(store: reopened, submitOccurrenceResult: { request in
            capture.requests.append(request)
            return .delivered
        })

        runtime.pollNow(at: oldDate, calendar: calendar)
        #expect(capture.requests.isEmpty, "旧 pinned occurrence 已成功，重开不可重复派发")
        guard let oldAfterReopen = reopened.occurrence(id: oldOccurrence.id) else {
            Issue.record("重开后旧 occurrence 必须保留为可审计历史")
            return
        }
        #expect(oldAfterReopen.state == .succeeded)
        #expect(oldAfterReopen.taskVersion == originalTask.version)
        #expect(oldAfterReopen.command == "old-command")
        #expect(oldAfterReopen.targetSessionID == oldSession)
        #expect(oldAfterReopen.targetProjectID == "old-project")
        #expect(oldAfterReopen.targetTurnID == 7)
        #expect(oldAfterReopen.submissionReceipt?.request == pinnedRequest)
        let reopenedReceiptBytes = try canonicalEncoder.encode(oldAfterReopen.submissionReceipt)
        #expect(reopenedReceiptBytes == pinnedReceiptBytes)

        let newDate = oldDate.addingTimeInterval(60)
        runtime.pollNow(at: newDate, calendar: calendar)
        #expect(capture.requests.isEmpty, "新版本未重新授权前不得执行")
        guard let pendingNew = reopened.occurrences.first(where: {
            $0.taskID == originalTask.id && $0.taskVersion == updatedTask.version
        }) else {
            Issue.record("新匹配分钟必须生成新版本 occurrence")
            return
        }
        #expect(pendingNew.id != oldOccurrence.id)
        #expect(pendingNew.command == "new-command")
        #expect(pendingNew.targetSessionID == newSession)
        #expect(pendingNew.targetProjectID == "new-project")
        #expect(pendingNew.targetTurnID == 8)
        #expect(pendingNew.state == .waitingApproval)

        #expect(reopened.authorize(
            originalTask.id,
            actorID: "actor-v2",
            scopeID: "scope-v2",
            policyRevision: "policy-v2"
        ))
        runtime.pollNow(at: newDate.addingTimeInterval(20), calendar: calendar)
        #expect(capture.requests.count == 1)
        guard let newRequest = capture.requests.first else {
            Issue.record("新版本授权后必须有一次真实 Runtime request")
            return
        }
        #expect(newRequest.occurrenceID == pendingNew.id)
        #expect(newRequest.taskID == originalTask.id)
        #expect(newRequest.taskVersion == updatedTask.version)
        #expect(newRequest.command == "new-command")
        #expect(newRequest.targetSessionID == newSession)
        #expect(newRequest.targetProjectID == "new-project")
        #expect(newRequest.targetTurnID == 8)
        #expect(reopened.occurrence(id: newRequest.occurrenceID)?.state == .succeeded)

        runtime.pollNow(at: newDate.addingTimeInterval(40), calendar: calendar)
        #expect(capture.requests.count == 1, "同一分钟重复 poll 不得重复派发新版本")
        let finalReceiptBytes = try canonicalEncoder.encode(
            reopened.occurrence(id: oldOccurrence.id)?.submissionReceipt
        )
        let finalJournalBytes = try canonicalEncoder.encode(reopened.occurrenceJournal.filter {
            $0.occurrenceID == oldOccurrence.id
        })
        #expect(finalReceiptBytes == pinnedReceiptBytes)
        #expect(finalJournalBytes == pinnedJournalBytes)
    }

    @Test func renameOnlyKeepsPinnedGrantAndCreatesNewVersionAttempt() throws {
        let (store, defaults, ledger, cleanup) = makeReopenableStore()
        defer { cleanup() }
        let oldDate = Date(timeIntervalSince1970: 1_756_650_000)
        let targetSession = UUID()
        #expect(store.add(name: "旧显示名", cronExpression: "* * * * *",
            command: "same-command", targetSessionID: targetSession,
            targetProjectID: "same-project", targetTurnID: 7) == nil)
        let original = try #require(store.allTasks().first)
        #expect(store.authorize(original.id, actorID: "actor-v1", scopeID: "same-project",
            policyRevision: "policy-v1"))
        let oldOccurrence = try #require(store.reserveOccurrence(taskID: original.id, at: oldDate))

        var renamed = try #require(store.task(id: original.id))
        renamed.name = "新显示名"
        #expect(store.update(renamed, expectedVersion: original.version) == nil)
        let updated = try #require(store.task(id: original.id))
        #expect(updated.version == original.version + 1)
        #expect(updated.authorizationVersion == original.authorizationVersion)
        #expect(updated.isAuthorized)

        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        let capture = SchedulerRuntimeRequestCapture()
        let runtime = SchedulerTaskRuntime(store: reopened, submitOccurrenceResult: { request in
            capture.requests.append(request)
            return .delivered
        })
        runtime.pollNow(at: oldDate)
        let pinned = try #require(capture.requests.first)
        #expect(capture.requests.count == 1)
        #expect(pinned.occurrenceID == oldOccurrence.id)
        #expect(pinned.taskVersion == original.version)
        #expect(pinned.command == "same-command")
        #expect(pinned.targetSessionID == targetSession)
        #expect(reopened.occurrence(id: oldOccurrence.id)?.state == .succeeded)
        let canonicalEncoder = JSONEncoder()
        canonicalEncoder.outputFormatting = [.sortedKeys]
        let oldReceiptBytes = try canonicalEncoder.encode(
            reopened.occurrence(id: oldOccurrence.id)?.submissionReceipt
        )
        let oldJournalBytes = try canonicalEncoder.encode(reopened.occurrenceJournal.filter {
            $0.occurrenceID == oldOccurrence.id
        })

        runtime.pollNow(at: oldDate.addingTimeInterval(60))
        let current = try #require(capture.requests.last)
        #expect(capture.requests.count == 2)
        #expect(current.occurrenceID != pinned.occurrenceID)
        #expect(current.idempotencyKey != pinned.idempotencyKey)
        #expect(current.taskVersion == updated.version)
        #expect(current.command == "same-command")
        #expect(current.targetSessionID == targetSession)
        #expect(reopened.occurrence(id: current.occurrenceID)?.state == .succeeded)
        let finalOldReceiptBytes = try canonicalEncoder.encode(
            reopened.occurrence(id: oldOccurrence.id)?.submissionReceipt
        )
        let finalOldJournalBytes = try canonicalEncoder.encode(reopened.occurrenceJournal.filter {
            $0.occurrenceID == oldOccurrence.id
        })
        #expect(finalOldReceiptBytes == oldReceiptBytes)
        #expect(finalOldJournalBytes == oldJournalBytes)
    }

    @Test func revokedTaskCannotBeRevivedByScopeEditOrOldPinnedResult() throws {
        let (store, defaults, ledger, cleanup) = makeReopenableStore()
        defer { cleanup() }
        let oldDate = Date(timeIntervalSince1970: 1_756_650_000)
        let oldSession = UUID()
        let newSession = UUID()
        #expect(store.add(name: "可撤权计划", cronExpression: "* * * * *",
            command: "old-command", targetSessionID: oldSession,
            targetProjectID: "old-project", targetTurnID: 1) == nil)
        let initial = try #require(store.allTasks().first)
        #expect(store.authorize(initial.id, actorID: "user", scopeID: "old-project",
            policyRevision: "policy-v1"))
        let authorized = try #require(store.task(id: initial.id))
        let capture = SchedulerRuntimeRequestCapture()
        let runtime = SchedulerTaskRuntime(store: store, submitRequest: { capture.requests.append($0) })
        runtime.pollNow(at: oldDate)
        let oldRequest = try #require(capture.requests.first)
        let oldOccurrence = try #require(store.occurrence(id: oldRequest.occurrenceID))
        let oldJournal = store.occurrenceJournal.filter { $0.occurrenceID == oldOccurrence.id }
        let oldReceipt = oldOccurrence.submissionReceipt

        // The Settings revoke action is the production caller of the store
        // boundary. A stale displayed snapshot cannot revoke a new grant.
        #expect(SchedulerTaskAuthorizationRevocationConsumer.revoke(authorized, store: store))
        let revoked = try #require(store.task(id: initial.id))
        #expect(revoked.authorizationVersion == authorized.authorizationVersion + 1)
        #expect(revoked.revokedAuthorizationThroughVersion == authorized.authorizationVersion)
        #expect(revoked.authorizationRevoked && !revoked.isAuthorized)
        #expect(!SchedulerTaskAuthorizationRevocationConsumer.revoke(authorized, store: store))

        var edited = revoked
        edited.command = "new-command"
        edited.targetSessionID = newSession
        edited.targetProjectID = "new-project"
        edited.targetTurnID = 2
        edited.authorizationPolicyRevision = "policy-v2"
        #expect(store.update(edited, expectedVersion: revoked.version) == nil)
        let afterEdit = try #require(store.task(id: initial.id))
        #expect(afterEdit.authorizationVersion == revoked.authorizationVersion + 1)
        #expect(afterEdit.authorizationRevoked && !afterEdit.isAuthorized)
        #expect(afterEdit.revokedAuthorizationThroughVersion == revoked.revokedAuthorizationThroughVersion)

        let nextDate = oldDate.addingTimeInterval(60)
        runtime.pollNow(at: nextDate)
        #expect(capture.requests.count == 1, "撤权后编辑不能自动恢复 dispatch")
        let pending = try #require(store.occurrences.first {
            $0.taskID == initial.id && $0.taskVersion == afterEdit.version
        })
        #expect(pending.state == .waitingApproval)

        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        let reopenedCapture = SchedulerRuntimeRequestCapture()
        let reopenedRuntime = SchedulerTaskRuntime(store: reopened,
            submitRequest: { reopenedCapture.requests.append($0) })
        reopenedRuntime.pollNow(at: nextDate.addingTimeInterval(20))
        #expect(reopenedCapture.requests.isEmpty)
        #expect(reopened.task(id: initial.id)?.authorizationRevoked == true)

        #expect(reopened.authorize(initial.id, actorID: "user", scopeID: "new-project",
            policyRevision: "policy-v2"))
        #expect(!reopened.isOccurrenceAuthorized(oldOccurrence, now: nextDate),
            "显式重新授权不能复活撤权前的 pinned grant")
        reopenedRuntime.pollNow(at: nextDate.addingTimeInterval(30))
        #expect(reopenedCapture.requests.count == 1)
        #expect(reopenedCapture.requests.first?.occurrenceID == pending.id)
        #expect(reopenedCapture.requests.first?.command == "new-command")
        #expect(reopened.occurrence(id: oldOccurrence.id)?.submissionReceipt == oldReceipt)
        #expect(reopened.occurrenceJournal.filter { $0.occurrenceID == oldOccurrence.id } == oldJournal)
    }

    @Test func unknownOldVersionCannotBeResentAsNewVersionInSameMinute() throws {
        let (store, defaults, ledger, cleanup) = makeReopenableStore()
        defer { cleanup() }
        let minute = Date(timeIntervalSince1970: 1_756_650_000)
        let firstTarget = UUID()
        let secondTarget = UUID()
        #expect(store.add(
            name: "同分钟版本隔离", cronExpression: "* * * * *", command: "v1 prompt",
            targetSessionID: firstTarget, targetProjectID: "project-v1", targetTurnID: 1
        ) == nil)
        let initialTask = try #require(store.allTasks().first)
        #expect(store.authorize(initialTask.id, actorID: "actor-v1", scopeID: "project-v1",
                                policyRevision: "policy-v1"))
        let firstCapture = SchedulerRuntimeRequestCapture()
        let firstRuntime = SchedulerTaskRuntime(store: store, submitOccurrenceResult: { request in
            firstCapture.requests.append(request)
            return .unknown
        })
        firstRuntime.pollNow(at: minute)
        let firstRequest = try #require(firstCapture.requests.first)
        let uncertain = try #require(store.occurrence(id: firstRequest.occurrenceID))
        #expect(firstCapture.requests.count == 1)
        #expect(uncertain.state == .unknown)
        #expect(uncertain.submissionReceipt?.request == firstRequest)

        var edited = try #require(store.task(id: initialTask.id))
        edited.command = "v2 prompt"
        edited.targetSessionID = secondTarget
        edited.targetProjectID = "project-v2"
        edited.targetTurnID = 2
        #expect(store.update(edited, expectedVersion: edited.version) == nil)
        let secondTask = try #require(store.task(id: initialTask.id))
        #expect(secondTask.version == initialTask.version + 1)
        #expect(store.authorize(secondTask.id, actorID: "actor-v2", scopeID: "project-v2",
                                policyRevision: "policy-v2"))
        let secondCapture = SchedulerRuntimeRequestCapture()
        let secondRuntime = SchedulerTaskRuntime(store: store, submitOccurrenceResult: { request in
            secondCapture.requests.append(request)
            return .delivered
        })
        secondRuntime.pollNow(at: minute.addingTimeInterval(20))
        #expect(secondCapture.requests.isEmpty, "v1 UNKNOWN 未对账，不得用 v2 同分钟自动再投递")
        #expect(store.occurrences.count == 1)
        #expect(store.occurrence(id: uncertain.id)?.submissionReceipt?.request == firstRequest)

        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        let reopenCapture = SchedulerRuntimeRequestCapture()
        let reopenedRuntime = SchedulerTaskRuntime(store: reopened, submitOccurrenceResult: { request in
            reopenCapture.requests.append(request)
            return .delivered
        })
        reopenedRuntime.pollNow(at: minute.addingTimeInterval(40))
        #expect(reopenCapture.requests.isEmpty)
        #expect(reopened.occurrences.count == 1)
        #expect(reopened.occurrence(id: uncertain.id)?.state == .unknown)

        reopenedRuntime.pollNow(at: minute.addingTimeInterval(60))
        let nextMinute = try #require(reopenCapture.requests.first)
        #expect(reopenCapture.requests.count == 1)
        #expect(nextMinute.taskVersion == secondTask.version)
        #expect(nextMinute.command == "v2 prompt")
        #expect(nextMinute.targetSessionID == secondTarget)
        #expect(nextMinute.occurrenceID != uncertain.id)
    }

    @Test func editedInFlightOccurrenceCompletesWithPinnedOldIdentity() async throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let originalTask = addAuthorizedTask(to: store)
        var anchoredTask = originalTask
        anchoredTask.sourceAnchorDigest = String(repeating: "a", count: 64)
        #expect(store.update(anchoredTask, expectedVersion: originalTask.version) == nil)
        #expect(store.authorize(originalTask.id))
        let task = try #require(store.task(id: originalTask.id))
        let date = Date(timeIntervalSince1970: 1_756_650_000)
        let probe = SchedulerRuntimeEffectProbe()
        defer { probe.release(status: .unknown) }
        let runtime = SchedulerTaskRuntime(
            store: store,
            now: { date },
            submitEffect: { context in
                try await probe.submit(context)
            }
        )

        runtime.pollNow(at: date)
        try await probe.waitUntilStarted()
        guard let oldRequest = probe.contexts.first?.request else {
            Issue.record("in-flight 回归必须由真实 Runtime effect seam 启动旧 request")
            return
        }
        #expect(probe.contexts.count == 1)
        #expect(oldRequest.command == task.command)
        #expect(oldRequest.targetSessionID == task.targetSessionID)
        #expect(oldRequest.targetProjectID == task.targetProjectID)
        #expect(oldRequest.targetTurnID == task.targetTurnID)
        #expect(store.occurrence(id: oldRequest.occurrenceID)?.state == .running)

        var edited = task
        edited.command = "edited-in-flight-command"
        edited.targetSessionID = UUID()
        edited.targetProjectID = "edited-in-flight-project"
        edited.targetTurnID = 8
        edited.authorizationPolicyRevision = "policy-v2"
        #expect(store.update(edited, expectedVersion: task.version) == nil)
        #expect(probe.contexts.first?.request == oldRequest)
        #expect(store.occurrence(id: oldRequest.occurrenceID)?.state == .running)

        // The old effect was already admitted. An edit cannot relabel its
        // immutable request or erase the receipt for its pinned version.
        probe.release(status: .delivered)
        for _ in 0..<50 {
            if store.occurrence(id: oldRequest.occurrenceID)?.state == .succeeded {
                break
            }
            await Task.yield()
        }

        guard let afterEdit = store.occurrence(id: oldRequest.occurrenceID) else {
            Issue.record("旧 in-flight occurrence 必须保留")
            return
        }
        #expect(afterEdit.state == .succeeded)
        #expect(afterEdit.submissionReceipt?.status == .delivered)
        #expect(afterEdit.submissionReceipt?.request == oldRequest)
        #expect(afterEdit.submissionReceipt?.request.command == task.command)
        #expect(afterEdit.submissionReceipt?.request.targetSessionID == task.targetSessionID)
        #expect(afterEdit.submissionReceipt?.request.targetProjectID == task.targetProjectID)
        #expect(afterEdit.submissionReceipt?.request.targetTurnID == task.targetTurnID)
        #expect(store.occurrences.filter { $0.taskID == task.id }.count == 1)
    }

    @Test func revokedInFlightResultStaysRejectedAfterExplicitReauthorization() async throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let initial = addAuthorizedTask(to: store)
        let date = Date(timeIntervalSince1970: 1_756_650_000)
        let probe = SchedulerRuntimeEffectProbe()
        defer { probe.release(status: .unknown) }
        let runtime = SchedulerTaskRuntime(store: store, now: { date },
            submitEffect: { context in try await probe.submit(context) })

        runtime.pollNow(at: date)
        try await probe.waitUntilStarted()
        let oldRequest = try #require(probe.contexts.first?.request)
        let before = try #require(store.occurrence(id: oldRequest.occurrenceID))
        #expect(before.state == .running)
        #expect(store.revokeAuthorization(initial.id))
        let revoked = try #require(store.task(id: initial.id))
        var edited = revoked
        edited.command = "newly-approved-command"
        edited.targetProjectID = "newly-approved-project"
        #expect(store.update(edited, expectedVersion: revoked.version) == nil)
        #expect(store.authorize(initial.id, actorID: "user", scopeID: "newly-approved-project",
            policyRevision: "scheduler-policy-v1"))
        #expect(!probe.contexts[0].isCurrent())
        #expect(!store.isOccurrenceAuthorized(before, now: date))

        probe.release(status: .delivered)
        for _ in 0..<50 {
            if store.occurrence(id: oldRequest.occurrenceID)?.state == .unknown { break }
            await Task.yield()
        }
        let settled = try #require(store.occurrence(id: oldRequest.occurrenceID))
        #expect(settled.state == .unknown)
        #expect(settled.submissionReceipt?.status != .delivered)
        #expect(settled.command == oldRequest.command)
        #expect(settled.taskVersion == oldRequest.taskVersion)
    }

}
