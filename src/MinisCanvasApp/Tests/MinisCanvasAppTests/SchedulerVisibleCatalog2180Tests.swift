import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("2180 Scheduler visible read-only catalog", .serialized)
@MainActor
struct SchedulerVisibleCatalog2180Tests {
    private let definitionsKey = "miniscanvas.scheduler.tasks.v1"

    private func fixture(_ tasks: [SchedulerTask]) throws -> (SchedulerTaskStore, UserDefaults, String, URL) {
        let name = "SchedulerVisible2180.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.set(try JSONEncoder().encode(tasks), forKey: definitionsKey)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SchedulerVisible2180-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let ledger = root.appendingPathComponent("synthetic-occurrences.json")
        return (SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger), defaults, name, ledger)
    }

    private func task(session: UUID? = nil, project: String? = nil, turn: Int? = nil,
                      deleted: Bool = false, name: String = "Visible schedule") -> SchedulerTask {
        SchedulerTask(name: name, cronExpression: "0 9 * * *", isEnabled: false,
                      command: "SYNTHETIC_PRIVATE_PROMPT_ENV_2180", authorizationActorID: "SYNTHETIC_PRIVATE_ACTOR_2180",
                      isDeleted: deleted, targetSessionID: session, targetProjectID: project, targetTurnID: turn)
    }

    @Test("only live matching target rows project four safe fields without a Store write")
    func safeVisibleProjection() throws {
        let session = UUID()
        let scope = MemoryScope(sessionID: session.uuidString, projectID: "synthetic-project")
        let visible = task(session: session, project: scope.projectID, turn: 1)
        let hidden = [task(session: UUID(), project: scope.projectID, turn: 1),
                      task(session: session, project: "other-project", turn: 1), task(),
                      task(session: session, project: "", turn: 1),
                      task(session: session, project: scope.projectID, turn: 0),
                      task(session: session, project: scope.projectID, turn: 1, deleted: true)]
        let (store, defaults, name, ledger) = try fixture([visible] + hidden)
        defer { defaults.removePersistentDomain(forName: name) }
        let before = defaults.data(forKey: definitionsKey)
        let tasks = store.tasks
        let values = try SchedulerStoreTypedCatalogAdapter.snapshotVisible(
            to: scope, approvedSessionID: scope.sessionID, preferencesDefaults: defaults, from: store
        ).get()
        let id = SchedulerStoreTypedCatalogAdapter.settingID(taskID: visible.id, field: "name")
        #expect(values.count == 4)
        #expect(values[id] == .text(visible.name))
        #expect(values[SchedulerStoreTypedCatalogAdapter.settingID(taskID: visible.id, field: "cron-expression")] == .text("0 9 * * *"))
        #expect(values[SchedulerStoreTypedCatalogAdapter.settingID(taskID: visible.id, field: "enabled")] == .toggle(false))
        #expect(values[SchedulerStoreTypedCatalogAdapter.settingID(taskID: visible.id, field: "authorized")] == .toggle(false))
        for task in hidden {
            #expect(!values.keys.contains { $0.contains(task.id.uuidString.lowercased()) })
        }
        #expect(!String(describing: values).contains("SYNTHETIC_PRIVATE"))
        #expect(!values.keys.contains { $0.hasSuffix(".command") || $0.contains("target") || $0.contains("authorization") })
        #expect(defaults.data(forKey: definitionsKey) == before)
        #expect(store.tasks == tasks)
        #expect(store.occurrences.isEmpty && store.occurrenceJournal.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: ledger.path))
    }

    @Test("visible authorization metadata follows only canonical authorize and revoke across reopen")
    func canonicalAuthorizationBitIsReadOnly2893() throws {
        let session = UUID()
        let scope = MemoryScope(sessionID: session.uuidString, projectID: "synthetic-project")
        let visible = task(session: session, project: scope.projectID, turn: 1)
        let hidden = task(session: UUID(), project: scope.projectID, turn: 1)
        let (store, defaults, name, ledger) = try fixture([visible, hidden])
        defer { defaults.removePersistentDomain(forName: name) }
        let key = SchedulerStoreTypedCatalogAdapter.settingID(taskID: visible.id, field: "authorized")
        func read(_ owner: SchedulerTaskStore) throws -> [String: BL6SettingValue] {
            let definitionsBefore = defaults.data(forKey: definitionsKey)
            let tasksBefore = owner.tasks
            let occurrencesBefore = owner.occurrences
            let journalBefore = owner.occurrenceJournal
            let values = try SchedulerStoreTypedCatalogAdapter.snapshotVisible(
                to: scope, approvedSessionID: scope.sessionID,
                preferencesDefaults: defaults, from: owner
            ).get()
            #expect(defaults.data(forKey: definitionsKey) == definitionsBefore)
            #expect(owner.tasks == tasksBefore)
            #expect(owner.occurrences == occurrencesBefore)
            #expect(owner.occurrenceJournal == journalBefore)
            #expect(!values.keys.contains { $0.contains(hidden.id.uuidString.lowercased()) })
            #expect(!String(describing: values).contains("SYNTHETIC_PRIVATE"))
            return values
        }
        #expect(try read(store)[key] == .toggle(false))
        #expect(store.authorize(visible.id, actorID: "SYNTHETIC_PRIVATE_ACTOR_2180"))
        #expect(store.authorize(hidden.id, actorID: "SYNTHETIC_PRIVATE_HIDDEN_2180"))
        #expect(try read(store)[key] == .toggle(true))
        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(try read(reopened)[key] == .toggle(true))
        #expect(reopened.revokeAuthorization(visible.id))
        let revoked = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(try read(revoked)[key] == .toggle(false))
        #expect(revoked.occurrences.isEmpty && revoked.occurrenceJournal.isEmpty)
    }

    @Test("scope and approval identities fail closed while an unrelated valid scope sees no rows")
    func scopeIsolation() throws {
        let session = UUID()
        let scope = MemoryScope(sessionID: session.uuidString, projectID: "synthetic-project")
        let (store, defaults, name, _) = try fixture([task(session: session, project: scope.projectID, turn: 1), task()])
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(SchedulerStoreTypedCatalogAdapter.snapshotVisible(to: scope, approvedSessionID: UUID().uuidString,
                                                                 preferencesDefaults: defaults, from: store) == .failure(.notVisible))
        #expect(SchedulerStoreTypedCatalogAdapter.snapshotVisible(to: MemoryScope(sessionID: scope.sessionID, projectID: " "),
                                                                 approvedSessionID: scope.sessionID, preferencesDefaults: defaults, from: store) == .failure(.notVisible))
        let otherSession = MemoryScope(sessionID: UUID().uuidString, projectID: scope.projectID)
        let otherProject = MemoryScope(sessionID: scope.sessionID, projectID: "other-project")
        for other in [otherSession, otherProject] {
            #expect(try SchedulerStoreTypedCatalogAdapter.snapshotVisible(to: other, approvedSessionID: other.sessionID,
                                                                          preferencesDefaults: defaults, from: store).get().isEmpty)
        }
    }

    @Test("another preferences object is not the admitted profile, including the same suite")
    func preferencesIdentity() throws {
        let session = UUID()
        let scope = MemoryScope(sessionID: session.uuidString, projectID: "synthetic-project")
        let (store, defaults, name, _) = try fixture([task(session: session, project: scope.projectID, turn: 1)])
        defer { defaults.removePersistentDomain(forName: name) }
        let sameSuite = try #require(UserDefaults(suiteName: name))
        #expect(SchedulerStoreTypedCatalogAdapter.usesPreferencesDomain(defaults, in: store))
        #expect(!SchedulerStoreTypedCatalogAdapter.usesPreferencesDomain(sameSuite, in: store))
        #expect(SchedulerStoreTypedCatalogAdapter.snapshotVisible(to: scope, approvedSessionID: scope.sessionID,
                                                                 preferencesDefaults: sameSuite, from: store) == .failure(.unavailable))
    }

    @Test("invalid legacy task definitions retain their bytes and make the catalog unavailable")
    func invalidStoreIsUnavailable() throws {
        let session = UUID()
        let scope = MemoryScope(sessionID: session.uuidString, projectID: "synthetic-project")
        let (good, defaults, name, ledger) = try fixture([task(session: session, project: scope.projectID, turn: 1)])
        defer { defaults.removePersistentDomain(forName: name) }
        let original = try #require(defaults.data(forKey: definitionsKey))
        var rows = try #require(try JSONSerialization.jsonObject(with: original) as? [[String: Any]])
        rows[0]["enablementRevision"] = 0
        let invalid = try JSONSerialization.data(withJSONObject: rows, options: .sortedKeys)
        defaults.set(invalid, forKey: definitionsKey)
        let rejected = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(good.persistenceError == nil)
        #expect(rejected.persistenceError != nil)
        #expect(SchedulerStoreTypedCatalogAdapter.snapshotVisible(to: scope, approvedSessionID: scope.sessionID,
                                                                 preferencesDefaults: defaults, from: rejected) == .failure(.unavailable))
        #expect(defaults.data(forKey: definitionsKey) == invalid)
        #expect(rejected.occurrences.isEmpty && rejected.occurrenceJournal.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: ledger.path))
    }
}
