import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("2113 Scheduler Store typed proposal", .serialized)
@MainActor
struct SchedulerStoreTypedCatalogAdapter2113Tests {
    private func fixture() throws -> (SchedulerTaskStore, UserDefaults, String, URL) {
        let domain = "SchedulerTyped2113.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SchedulerTyped2113-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledger = root.appendingPathComponent("occurrences.json")
        return (SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger), defaults, domain, ledger)
    }

    @Test("exact Store row projects only visible nonsecret settings; preview never writes")
    func visibleProposalAndReopen() throws {
        let (store, defaults, domain, ledger) = try fixture()
        defer { defaults.removePersistentDomain(forName: domain) }
        #expect(store.add(name: "Morning", cronExpression: "0 9 * * *",
                          command: "synthetic private command", isEnabled: false) == nil)
        let task = try #require(store.allTasks().first)
        let visible: (SchedulerTask) -> Bool = {
            $0.id == task.id && $0.authorizationActorID == "local-user"
        }
        guard case .success(let snapshot) = SchedulerStoreTypedCatalogAdapter.snapshot(
            taskID: task.id, visibleTo: visible, in: store
        ) else {
            Issue.record("The exact visible Store row should project")
            return
        }
        let nameID = SchedulerStoreTypedCatalogAdapter.settingID(taskID: task.id, field: "name")
        let cronID = SchedulerStoreTypedCatalogAdapter.settingID(taskID: task.id, field: "cron-expression")
        let enabledID = SchedulerStoreTypedCatalogAdapter.settingID(taskID: task.id, field: "enabled")
        #expect(snapshot.values.count == 4)
        #expect(snapshot.values[nameID] == .text("Morning"))
        #expect(snapshot.values[cronID] == .text("0 9 * * *"))
        #expect(snapshot.values[enabledID] == .toggle(false))
        #expect(snapshot.values[SchedulerStoreTypedCatalogAdapter.settingID(taskID: task.id, field: "authorized")] == .toggle(false))
        #expect(!String(describing: snapshot.values).contains("synthetic private command"))

        guard case .success(let cronPreview) = SchedulerStoreTypedCatalogAdapter.preview(
            settingID: cronID, value: .text("  */5 * * * *  "),
            expectedVersion: snapshot.version,
            expectedEnablementRevision: snapshot.enablementRevision,
            visibleTo: visible, in: store
        ) else {
            Issue.record("Valid cron must make a normalized read-only proposal")
            return
        }
        #expect(cronPreview.before == .text("0 9 * * *"))
        #expect(cronPreview.proposed == .text("*/5 * * * *"))
        guard case .success(let enabledPreview) = SchedulerStoreTypedCatalogAdapter.preview(
            settingID: enabledID, value: .toggle(true),
            expectedVersion: snapshot.version,
            expectedEnablementRevision: snapshot.enablementRevision,
            visibleTo: visible, in: store
        ) else {
            Issue.record("Enabled toggle must preview without dispatch")
            return
        }
        #expect(enabledPreview.before == .toggle(false))
        #expect(enabledPreview.proposed == .toggle(true))
        #expect(store.task(id: task.id) == task)
        #expect(store.occurrences.isEmpty)
        #expect(store.occurrenceJournal.isEmpty)
        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(reopened.task(id: task.id) == task)
        #expect(reopened.occurrences.isEmpty)
    }

    @Test("visibility, identity, version, kind and cron checks fail closed")
    func rejectedProposalsDoNotMutateStore() throws {
        let (store, defaults, domain, ledger) = try fixture()
        defer { defaults.removePersistentDomain(forName: domain) }
        #expect(store.add(name: "Morning", cronExpression: "0 9 * * *",
                          command: "synthetic", isEnabled: false) == nil)
        let original = try #require(store.allTasks().first)
        let visible: (SchedulerTask) -> Bool = { $0.id == original.id }
        let cronID = SchedulerStoreTypedCatalogAdapter.settingID(taskID: original.id, field: "cron-expression")

        guard case .failure(.notVisible) = SchedulerStoreTypedCatalogAdapter.snapshot(
            taskID: original.id, visibleTo: { _ in false }, in: store
        ) else { Issue.record("A non-visible row must stay unavailable"); return }
        guard case .failure(.notVisible) = SchedulerStoreTypedCatalogAdapter.preview(
            settingID: cronID, value: .text("*/5 * * * *"),
            expectedVersion: original.version,
            expectedEnablementRevision: original.enablementRevision,
            visibleTo: { _ in false }, in: store
        ) else { Issue.record("A model-supplied task ID cannot bypass owner visibility"); return }
        guard case .failure(.unknownSetting) = SchedulerStoreTypedCatalogAdapter.preview(
            settingID: "scheduler.\(original.id.uuidString.lowercased()).command",
            value: .text("synthetic"), expectedVersion: original.version,
            expectedEnablementRevision: original.enablementRevision,
            visibleTo: visible, in: store
        ) else { Issue.record("Command is outside the safe typed projection"); return }
        guard case .failure(.unknownSetting) = SchedulerStoreTypedCatalogAdapter.preview(
            settingID: SchedulerStoreTypedCatalogAdapter.settingID(taskID: original.id, field: "authorized"),
            value: .toggle(true), expectedVersion: original.version,
            expectedEnablementRevision: original.enablementRevision,
            visibleTo: visible, in: store
        ) else { Issue.record("Authorization metadata cannot grant a preview or effect"); return }
        guard case .failure(.kindMismatch) = SchedulerStoreTypedCatalogAdapter.preview(
            settingID: cronID, value: .toggle(true), expectedVersion: original.version,
            expectedEnablementRevision: original.enablementRevision,
            visibleTo: visible, in: store
        ) else { Issue.record("Wrong typed kind must be rejected"); return }
        guard case .failure(.invalidValue) = SchedulerStoreTypedCatalogAdapter.preview(
            settingID: cronID, value: .text("60 * * * *"), expectedVersion: original.version,
            expectedEnablementRevision: original.enablementRevision,
            visibleTo: visible, in: store
        ) else { Issue.record("CronValidator must reject invalid schedule"); return }
        #expect(store.task(id: original.id) == original)

        var changed = original
        changed.name = "New name"
        #expect(store.update(changed, expectedVersion: original.version,
                             expectedEnablementRevision: original.enablementRevision) == nil)
        guard case .failure(.staleTask) = SchedulerStoreTypedCatalogAdapter.preview(
            settingID: cronID, value: .text("*/5 * * * *"), expectedVersion: original.version,
            expectedEnablementRevision: original.enablementRevision,
            visibleTo: visible, in: store
        ) else { Issue.record("Stale Store version must be rejected"); return }
        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(reopened.task(id: original.id)?.name == "New name")
        #expect(reopened.occurrences.isEmpty)
    }
}
