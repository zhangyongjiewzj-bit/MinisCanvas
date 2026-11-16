import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@MainActor
private final class SchedulerPreviewCredential2606 {
    var version = "binding:synthetic-v1|apply:synthetic-v1"

    func preflight(_ task: SchedulerTask, _ now: Date) -> SchedulerProviderPreflight {
        SchedulerProviderPreflight(
            providerID: "synthetic-provider",
            modelID: "synthetic-model",
            credentialVersion: version,
            status: .ready,
            detail: "ready"
        )
    }
}

@MainActor
private final class SchedulerPreviewEffect2606 {
    var contexts: [SchedulerExecutionContext] = []
    var currentAtEntry = false

    func submit(_ context: SchedulerExecutionContext) async throws -> SchedulerEffectOutcome {
        contexts.append(context)
        currentAtEntry = context.isCurrent()
        return SchedulerEffectOutcome(status: .delivered)
    }
}

@Suite("D-SCHEDA preview to durable runtime consumer")
@MainActor
struct SchedulerPreviewConsumer2606Tests {
    private func fixture() throws -> (SchedulerTaskStore, UserDefaults, URL, () -> Void) {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let domain = "scheduler-preview-2606-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let directory = formal.rootDirectory
            .appendingPathComponent(domain, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledger = directory.appendingPathComponent("occurrences.json")
        let store = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        return (store, defaults, ledger, {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    private func addTask(_ store: SchedulerTaskStore) throws -> SchedulerTask {
        #expect(store.add(name: "preview consumer", cronExpression: "* * * * *",
            command: "synthetic action", targetSessionID: UUID(),
            targetProjectID: "project-a", targetTurnID: 1) == nil)
        return try #require(store.allTasks().first)
    }

    private func anchoredPreview(
        _ store: SchedulerTaskStore, taskID: UUID, at now: Date
    ) throws -> SchedulerTaskPreview {
        var preview = try #require(store.preview(taskID: taskID, now: now,
            timeZone: TimeZone(identifier: "UTC")))
        preview.observedSourceAnchorDigest = String(repeating: "a", count: 64)
        preview.observedPolicyRevision = "policy-v1"
        return preview
    }

    private func confirm(_ store: SchedulerTaskStore, preview: SchedulerTaskPreview, at now: Date) -> Bool {
        store.confirmPreview(preview, actorID: "synthetic-user",
            scopeID: preview.targetProjectID ?? "", policyRevision: "policy-v1",
            now: now, sourceAnchorConfirmed: true,
            currentSourceAnchorDigest: String(repeating: "a", count: 64),
            currentPolicyRevision: "policy-v1")
    }

    @Test("target, version, expiration, and credential reference changes reject the old preview")
    func stalePreviewCannotAuthorizeOrDispatch() throws {
        let (store, _, _, cleanup) = try fixture()
        defer { cleanup() }
        let credentials = SchedulerPreviewCredential2606()
        store.providerPreflightResolver = { credentials.preflight($0, $1) }
        let task = try addTask(store)
        let now = Date(timeIntervalSince1970: 1_756_650_000)
        let original = try anchoredPreview(store, taskID: task.id, at: now)

        #expect(!confirm(store, preview: original, at: original.expiresAt))
        #expect(!store.task(id: task.id)!.isAuthorized)
        credentials.version = "binding:synthetic-v2|apply:synthetic-v1"
        #expect(!confirm(store, preview: original, at: now))
        #expect(!store.task(id: task.id)!.isAuthorized)
        let beforeEdit = try anchoredPreview(store, taskID: task.id, at: now)
        var edited = try #require(store.task(id: task.id))
        edited.targetProjectID = "project-b"
        #expect(store.update(edited, expectedVersion: edited.version) == nil)
        #expect(!confirm(store, preview: beforeEdit, at: now))
        #expect(store.task(id: task.id)?.version == task.version + 1)
        #expect(!store.task(id: task.id)!.isAuthorized)
        #expect(store.occurrences.isEmpty)
    }

    @Test("only a fresh four-fact preview permits a durable reopened runtime effect")
    func freshPreviewPersistsAndReopenedConsumerUsesItsVersion() async throws {
        let (store, defaults, ledger, cleanup) = try fixture()
        defer { cleanup() }
        let credentials = SchedulerPreviewCredential2606()
        store.providerPreflightResolver = { credentials.preflight($0, $1) }
        let task = try addTask(store)
        let now = Date(timeIntervalSince1970: 1_756_650_000)
        let preview = try anchoredPreview(store, taskID: task.id, at: now)
        let projection = SchedulerControlProductionProjection(preview: preview, occurrences: store.occurrences)
        #expect(projection.trigger.nextOccurrence == preview.predictedTriggers.first)
        #expect(projection.credential.credentialVersion == credentials.version)
        #expect(projection.target.projectID == "project-a")
        #expect(projection.pinnedVersion.taskVersion == task.version)
        #expect(!projection.canProduceDispatchIntent)

        let before = SchedulerPreviewEffect2606()
        let beforeRuntime = SchedulerTaskRuntime(store: store,
            providerPreflightResolver: { credentials.preflight($0, $1) },
            submitEffect: { try await before.submit($0) })
        let due = try #require(preview.predictedTriggers.first)
        beforeRuntime.pollNow(at: due)
        #expect(before.contexts.isEmpty)
        #expect(store.occurrences.allSatisfy { $0.state == .waitingApproval })
        #expect(store.occurrences.allSatisfy { $0.submissionReceipt == nil })

        #expect(confirm(store, preview: preview, at: now))
        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        reopened.providerPreflightResolver = { credentials.preflight($0, $1) }
        let authorized = try #require(reopened.task(id: task.id))
        #expect(authorized.isAuthorized)
        #expect(authorized.authorizationScopeID == "project-a")
        #expect(authorized.sourceAnchorDigest == String(repeating: "a", count: 64))
        // Binding the source anchor, and possibly a new wall-clock zone,
        // advances the definition version. The old occurrence stays fenced.
        #expect(authorized.version > preview.taskVersion)
        #expect(authorized.timeZoneIdentifier == preview.timeZoneIdentifier)
        #expect(reopened.occurrences.allSatisfy { $0.taskVersion == preview.taskVersion })

        let after = SchedulerPreviewEffect2606()
        let nextDue = due.addingTimeInterval(60)
        let runtime = SchedulerTaskRuntime(store: reopened,
            now: { nextDue },
            providerPreflightResolver: { credentials.preflight($0, $1) },
            submitEffect: { try await after.submit($0) })
        runtime.pollNow(at: nextDue)
        for _ in 0..<100 where after.contexts.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let context = try #require(after.contexts.first)
        #expect(context.request.taskID == task.id)
        #expect(context.request.taskVersion == authorized.version)
        #expect(context.request.targetProjectID == "project-a")
        #expect(context.providerPreflight?.credentialVersion == credentials.version)
        #expect(after.currentAtEntry)
        #expect(before.contexts.isEmpty)
        runtime.stop()
    }

    @Test func confirmedRegrantRebindsWaitingOccurrenceAfterReopen() throws {
        let (store, defaults, ledger, cleanup) = try fixture()
        defer { cleanup() }
        let task = try addTask(store)
        let now = Date(timeIntervalSince1970: 1_756_650_000)
        let originalPreview = try anchoredPreview(store, taskID: task.id, at: now)
        #expect(confirm(store, preview: originalPreview, at: now))
        #expect(store.revokeAuthorization(task.id))

        let due = try #require(originalPreview.predictedTriggers.first)
        let runtime = SchedulerTaskRuntime(store: store, submitCommand: { _ in
            Issue.record("A revoked occurrence must not dispatch")
        })
        runtime.pollNow(at: due)
        let waiting = try #require(store.latestOccurrence(for: task.id))
        #expect(waiting.state == .waitingApproval)
        #expect(waiting.authorizationPolicyRevision == "policy-v1")

        var preview = try anchoredPreview(store, taskID: task.id, at: due)
        preview.observedPolicyRevision = "policy-v2"
        #expect(store.confirmPreview(preview, actorID: "new-synthetic-user",
            scopeID: "project-a", policyRevision: "policy-v2", now: due,
            sourceAnchorConfirmed: true, currentSourceAnchorDigest: preview.observedSourceAnchorDigest,
            currentPolicyRevision: "policy-v2"))

        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        let grant = try #require(reopened.task(id: task.id))
        let authorized = try #require(reopened.occurrence(id: waiting.id))
        #expect(authorized.state == .authorized)
        #expect(authorized.taskVersion == waiting.taskVersion)
        #expect(authorized.idempotencyKey == waiting.idempotencyKey)
        #expect(authorized.scheduledMinute == waiting.scheduledMinute)
        #expect(authorized.authorizationVersion == grant.authorizationVersion)
        #expect(authorized.authorizationActorID == "new-synthetic-user")
        #expect(authorized.authorizationScopeID == "project-a")
        #expect(authorized.authorizationPolicyRevision == "policy-v2")
        #expect(!authorized.authorizationRevoked)
        #expect(reopened.occurrenceJournal.filter { $0.occurrenceID == waiting.id }.map(\.state)
            == [.triggered, .waitingApproval, .authorized])
    }

}
