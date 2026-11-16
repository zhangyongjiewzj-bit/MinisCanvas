import Foundation
import MinisCore

/// Read-only typed projection of an exact SchedulerTaskStore row. The caller
/// must supply a trusted current-profile visibility predicate; neither a
/// model-provided task ID nor this adapter grants access or permission to edit.
/// No keys are registered in the production BL6 catalog by this file.
@MainActor
enum SchedulerStoreTypedCatalogAdapter {
    enum Failure: Error, Equatable {
        case unavailable
        case notVisible
        case staleTask
        case unknownSetting
        case kindMismatch
        case invalidValue
    }

    struct Snapshot: Equatable {
        let taskID: UUID
        let version: Int
        let enablementRevision: Int
        let values: [String: BL6SettingValue]
    }

    struct Preview: Equatable {
        let taskID: UUID
        let version: Int
        let enablementRevision: Int
        let settingID: String
        let before: BL6SettingValue
        let proposed: BL6SettingValue
    }

    static func settingID(taskID: UUID, field: String) -> String {
        "scheduler.\(taskID.uuidString.lowercased()).\(field)"
    }

    static func snapshot(
        taskID: UUID,
        visibleTo owner: (SchedulerTask) -> Bool,
        in store: SchedulerTaskStore
    ) -> Result<Snapshot, Failure> {
        guard store.persistenceError == nil,
              let task = store.task(id: taskID), !task.isDeleted else {
            return .failure(.unavailable)
        }
        guard owner(task) else { return .failure(.notVisible) }
        return .success(Snapshot(
            taskID: taskID,
            version: task.version,
            enablementRevision: task.enablementRevision,
            values: [
                settingID(taskID: taskID, field: "name"): .text(task.name),
                settingID(taskID: taskID, field: "cron-expression"): .text(task.cronExpression),
                settingID(taskID: taskID, field: "enabled"): .toggle(task.isEnabled),
                // This is the canonical stored authorization bit, never an
                // execution permit. The existing scheduler owner still checks
                // its current scope, policy, expiry and occurrence fences.
                settingID(taskID: taskID, field: "authorized"): .toggle(task.isAuthorized),
            ]
        ))
    }

    /// Composition-root identity only; a suite name or model task ID cannot
    /// substitute for the exact preferences object admitted by Bridge.
    static func usesPreferencesDomain(_ candidate: UserDefaults, in store: SchedulerTaskStore) -> Bool {
        store.defaults === candidate
    }

    /// Aggregate the existing per-row projection for a trusted live read.
    /// The caller owns approval/profile binding; this helper neither grants
    /// visibility nor reads command, authorization context or occurrence payloads.
    static func snapshotVisible(
        to trustedScope: MemoryScope,
        approvedSessionID: String,
        preferencesDefaults: UserDefaults,
        from store: SchedulerTaskStore
    ) -> Result<[String: BL6SettingValue], Failure> {
        guard trustedScope.isValid,
              trustedScope.sessionID == approvedSessionID else { return .failure(.notVisible) }
        guard usesPreferencesDomain(preferencesDefaults, in: store),
              store.persistenceError == nil else { return .failure(.unavailable) }
        let visible: (SchedulerTask) -> Bool = { task in
            task.hasValidTarget
                && task.targetSessionID?.uuidString == trustedScope.sessionID
                && task.targetProjectID == trustedScope.projectID
        }
        var values: [String: BL6SettingValue] = [:]
        for task in store.allTasks() where visible(task) {
            switch snapshot(taskID: task.id, visibleTo: visible, in: store) {
            case .failure(let error): return .failure(error)
            case .success(let row): values.merge(row.values, uniquingKeysWith: { first, _ in first })
            }
        }
        return .success(values)
    }

    /// This is a settings proposal, not SchedulerTaskStore.preview, an
    /// execution preview, an authorization, or a durable transaction plan.
    static func preview(
        settingID: String,
        value: BL6SettingValue,
        expectedVersion: Int,
        expectedEnablementRevision: Int,
        visibleTo owner: (SchedulerTask) -> Bool,
        in store: SchedulerTaskStore
    ) -> Result<Preview, Failure> {
        guard let (taskID, field) = parse(settingID) else {
            return .failure(.unknownSetting)
        }
        guard store.persistenceError == nil,
              let task = store.task(id: taskID), !task.isDeleted else {
            return .failure(.unavailable)
        }
        guard owner(task) else { return .failure(.notVisible) }
        guard task.version == expectedVersion,
              task.enablementRevision == expectedEnablementRevision else {
            return .failure(.staleTask)
        }

        let before: BL6SettingValue
        let proposed: BL6SettingValue
        switch field {
        case "name":
            guard case .text(let name) = value else { return .failure(.kindMismatch) }
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  task.version < Int.max else { return .failure(.invalidValue) }
            before = .text(task.name)
            proposed = .text(name)
        case "cron-expression":
            guard case .text(let raw) = value else { return .failure(.kindMismatch) }
            let cron = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard CronValidator.validate(cron) == nil,
                  task.version < Int.max else { return .failure(.invalidValue) }
            before = .text(task.cronExpression)
            proposed = .text(cron)
        case "enabled":
            guard case .toggle(let enabled) = value else { return .failure(.kindMismatch) }
            guard task.enablementRevision > 0,
                  (task.isEnabled == enabled || task.enablementRevision < Int.max) else {
                return .failure(.invalidValue)
            }
            before = .toggle(task.isEnabled)
            proposed = .toggle(enabled)
        default:
            return .failure(.unknownSetting)
        }

        return .success(Preview(
            taskID: taskID,
            version: task.version,
            enablementRevision: task.enablementRevision,
            settingID: settingID,
            before: before,
            proposed: proposed
        ))
    }

    private static func parse(_ settingID: String) -> (UUID, String)? {
        let parts = settingID.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == "scheduler",
              let taskID = UUID(uuidString: String(parts[1])),
              Self.settingID(taskID: taskID, field: String(parts[2])) == settingID,
              ["name", "cron-expression", "enabled"].contains(String(parts[2])) else {
            return nil
        }
        return (taskID, String(parts[2]))
    }
}

extension SchedulerStoreTypedCatalogAdapter {
    /// Same visibility the read projection uses: tasks whose target is the current session and project.
    static func isVisible(_ task: SchedulerTask, to scope: MemoryScope) -> Bool {
        task.hasValidTarget
            && task.targetSessionID?.uuidString == scope.sessionID
            && task.targetProjectID == scope.projectID
    }

    /// Revision of the visible rows (id, version, enablement revision); changes on add, delete and toggle.
    static func revision(visibleTo scope: MemoryScope?, in store: SchedulerTaskStore) -> String {
        let lines = store.allTasks()
            .filter { task in scope.map { isVisible(task, to: $0) } ?? false }
            .map { "\($0.id.uuidString)|\($0.version)|\($0.enablementRevision)" }
        return DeletionGate.fingerprint(Data(lines.sorted().joined(separator: "\n").utf8))
    }
}
