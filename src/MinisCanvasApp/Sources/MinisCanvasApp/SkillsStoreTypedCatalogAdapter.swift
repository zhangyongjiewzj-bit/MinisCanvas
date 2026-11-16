import Foundation
import MinisCore

/// Typed projections of the existing Skills settings owner. The general
/// directory remains read-only; an approved enablement writer additionally
/// requires the canonical Core snapshot of an existing active lifecycle grant.
/// This adapter never imports, activates or grants a skill.
@MainActor
enum SkillsStoreTypedCatalogAdapter {
    enum ProjectionError: Error, Equatable {
        case catalogUnavailable
        case duplicateEntry
        case unknownSetting
        case invalidValue
        case pendingReview
        case unchanged
        case stalePreview
        case untrustedOwner
    }

    struct Preview: Equatable {
        let settingID: String
        let skillID: String
        let source: SkillSource
        let version: String
        let catalogGeneration: UInt64
        let currentEnabled: Bool
        let proposedEnabled: Bool

        /// The caller must use the existing skill approval and enablement owner.
        var requiresLifecycleApproval: Bool { true }
    }

    static func settingID(for entry: SkillEntry) -> String {
        "skills.\(entry.id).enabled"
    }

    static func snapshot(from store: SkillsStore) throws -> [String: BL6SettingValue] {
        guard store.catalogRefreshStatus == .ready else {
            throw ProjectionError.catalogUnavailable
        }
        var values: [String: BL6SettingValue] = [:]
        for entry in store.entries where !store.hasPendingLocalSkillReview(for: entry.id) {
            let id = settingID(for: entry)
            guard values[id] == nil else { throw ProjectionError.duplicateEntry }
            values[id] = .toggle(store.isEnabled(entry.id))
        }
        return values
    }

    /// The Provider read path must use the exact SkillsStore created by the
    /// App root for this profile. Equal skill IDs in another profile are not
    /// sufficient authority to project its enablement into this catalog.
    /// No path, skill body, receipt, or capability grant is returned.
    static func snapshot(
        from store: SkillsStore,
        boundTo trustedOwner: SkillsStore
    ) throws -> [String: BL6SettingValue] {
        guard store === trustedOwner else { throw ProjectionError.untrustedOwner }
        return try snapshot(from: store)
    }

    /// Mutability comes only from the canonical Core snapshot of currently
    /// active lifecycle grants. Foreign scopes and pending reviews
    /// metadata cannot be promoted into an approved writer by this adapter.
    static func approvedSnapshot(
        from store: SkillsStore, boundTo owner: SkillStore, visibleTo scope: MemoryScope
    ) throws -> BL6SkillEnablementSnapshot {
        guard store.catalogRefreshStatus == .ready else { throw ProjectionError.catalogUnavailable }
        let projection = try store.bl6EnablementSnapshot(visibleTo: scope, boundTo: owner)
        for (id, value) in projection.values {
            guard let entry = store.entries.first(where: { settingID(for: $0) == id }),
                  store.entries.filter({ settingID(for: $0) == id }).count == 1,
                  entry.source == .app,
                  !store.hasPendingLocalSkillReview(for: entry.id),
                  store.isEnabled(entry.id) == value else {
                throw ProjectionError.stalePreview
            }
        }
        return projection
    }

    static func preview(
        settingID: String,
        value: BL6SettingValue,
        in store: SkillsStore
    ) throws -> Preview {
        guard store.catalogRefreshStatus == .ready else {
            throw ProjectionError.catalogUnavailable
        }
        guard let entry = store.entries.first(where: { self.settingID(for: $0) == settingID }),
              store.entries.filter({ self.settingID(for: $0) == settingID }).count == 1 else {
            throw ProjectionError.unknownSetting
        }
        guard case .toggle(let proposedEnabled) = value else {
            throw ProjectionError.invalidValue
        }
        guard !store.hasPendingLocalSkillReview(for: entry.id) else {
            throw ProjectionError.pendingReview
        }
        let currentEnabled = store.isEnabled(entry.id)
        guard proposedEnabled != currentEnabled else { throw ProjectionError.unchanged }
        return Preview(
            settingID: settingID,
            skillID: entry.id,
            source: entry.source,
            version: entry.version,
            catalogGeneration: store.catalogRefreshGeneration,
            currentEnabled: currentEnabled,
            proposedEnabled: proposedEnabled
        )
    }

    /// A preview is informative only; this check is not a capability receipt.
    static func revalidate(_ preview: Preview, in store: SkillsStore) throws {
        guard store.catalogRefreshStatus == .ready,
              store.catalogRefreshGeneration == preview.catalogGeneration,
              let entry = store.entries.first(where: { $0.id == preview.skillID }),
              settingID(for: entry) == preview.settingID,
              entry.source == preview.source,
              entry.version == preview.version,
              !store.hasPendingLocalSkillReview(for: entry.id),
              store.isEnabled(entry.id) == preview.currentEnabled else {
            throw ProjectionError.stalePreview
        }
    }
}
