import Testing
import Foundation
@testable import MinisCanvasApp

private final class SchedulerPreflightBox: @unchecked Sendable {
    var value: SchedulerProviderPreflight

    init(_ value: SchedulerProviderPreflight) {
        self.value = value
    }
}

private final class SchedulerEffectSpy: @unchecked Sendable {
    var count = 0
}

@Suite("D-SCHEDA scheduler credential preflight")
@MainActor
struct SchedulerCredentialPreflightTests {
    private func makeStore() -> (SchedulerTaskStore, () -> Void) {
        let name = "scheduler-preflight-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let ledger = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-preflight-\(UUID().uuidString).json")
        let store = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        return (store, {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: ledger)
        })
    }

    private func preflight(
        providerID: String = "OpenAI",
        modelID: String = "gpt-5.5",
        credentialVersion: String? = "apply:credential-v1",
        status: SchedulerProviderPreflightStatus = .ready
    ) -> SchedulerProviderPreflight {
        SchedulerProviderPreflight(
            providerID: providerID,
            modelID: modelID,
            credentialVersion: credentialVersion,
            status: status,
            detail: status == .ready ? "ready" : "blocked"
        )
    }

    @Test("preview and confirmation bind the selected provider model and credential revision")
    func confirmationRevalidatesProviderPreflight() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.add(
            name: "scheduler-preflight",
            cronExpression: "* * * * *",
            command: "run",
            targetSessionID: UUID(),
            targetProjectID: "project",
            targetTurnID: 1
        )
        let task = store.allTasks()[0]
        let box = SchedulerPreflightBox(preflight())
        store.providerPreflightResolver = { _, _ in box.value }
        let now = Date(timeIntervalSince1970: 1_756_650_000)
        let preview = store.preview(taskID: task.id, now: now, timeZone: TimeZone(secondsFromGMT: 0)!)!

        #expect(preview.providerPreflight == box.value)
        box.value = preflight(credentialVersion: "apply:credential-v2")
        #expect(!store.confirmPreview(
            preview,
            actorID: "user",
            scopeID: "project",
            policyRevision: "policy",
            now: now
        ))
        #expect(store.task(id: task.id)?.isAuthorized == false)

        box.value = preflight(providerID: "Anthropic", modelID: "claude-sonnet-4.6")
        #expect(!store.confirmPreview(
            preview,
            actorID: "user",
            scopeID: "project",
            policyRevision: "policy",
            now: now
        ))
        #expect(store.task(id: task.id)?.isAuthorized == false)
    }

    @Test("missing preflight leaves the occurrence resumable and sends no request")
    func runtimeBlocksBeforeLeaseOrEffect() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.add(
            name: "blocked scheduler",
            cronExpression: "* * * * *",
            command: "run",
            targetSessionID: UUID(),
            targetProjectID: "project",
            targetTurnID: 1
        )
        let task = store.allTasks()[0]
        #expect(store.authorize(task.id, actorID: "user", scopeID: "project", policyRevision: "policy"))
        let box = SchedulerPreflightBox(preflight(status: .missingCredential))
        let effects = SchedulerEffectSpy()
        let runtime = SchedulerTaskRuntime(
            store: store,
            providerPreflightResolver: { _, _ in box.value },
            submitEffect: { _ in
                effects.count += 1
                return SchedulerEffectOutcome(status: .delivered)
            }
        )
        let now = Date(timeIntervalSince1970: 1_756_650_000)
        runtime.pollNow(at: now)

        #expect(effects.count == 0)
        #expect(store.latestOccurrence(for: task.id)?.state == .triggered)
        #expect(store.latestOccurrence(for: task.id)?.leaseToken == nil)
    }
}
