import MinisCore

enum SkillRuntimeEnablementError: Error, Equatable, Sendable {
    case invalidAppIdentifier
    case unknownSkill
    case rejected
}

enum SkillRuntimeEnablementResult: Equatable, Sendable {
    case applied
    case notApplicable
}

/// Bridges the settings-facing skill identifier to the live MinisCore store.
///
/// The settings facade uses namespaced identifiers (`app:<skill-id>`) so that
/// The runtime uses the unprefixed App skill id; the facade translates app:<id>
/// so every toggle changes the same canonical store used by SkillInjector.
struct SkillRuntimeEnablementBridge: Sendable {
    private let store: SkillStore

    init(store: SkillStore) {
        self.store = store
    }

    @discardableResult
    func setEnabled(
        for settingsID: String,
        enabled: Bool
    ) -> Result<SkillRuntimeEnablementResult, SkillRuntimeEnablementError> {
        guard settingsID.hasPrefix("app:") else { return .success(.notApplicable) }
        guard let skillID = Self.appSkillID(from: settingsID) else {
            return .failure(.invalidAppIdentifier)
        }
        guard store.allSkills().contains(where: { $0.id == skillID }) else {
            return .failure(.unknownSkill)
        }
        let enablementScope = enabled ? store.lifecycleReceipt(for: skillID)?.scope : nil
        if enabled {
            guard Self.lifecycleAllowsEnablement(for: skillID, in: store) else {
                return .failure(.rejected)
            }
        }
        guard store.setEnabled(skillID, enabled: enabled, within: enablementScope) else {
            return .failure(.rejected)
        }
        // This is the canonical-write stage. The owning Settings transaction
        // must publish its shared state and validate the effective projection
        // and lifecycle before reporting management success.
        // .applied 仅为中间阶段；调用方须完成最终有效读回和后验审批，才可报告管理 success。
        return .success(.applied)
    }

    func bl6EnablementSnapshot(visibleTo scope: MemoryScope) throws -> BL6SkillEnablementSnapshot {
        try store.bl6SkillEnablementSnapshot(visibleTo: scope)
    }

    /// Uses the same SkillStore as ordinary runtime toggles, preserving its
    /// lifecycle/content/scope checks instead of supplying a new approval.
    func commitApprovedBL6Enablement(
        skillID: String, enabled: Bool, visibleTo scope: MemoryScope,
        profileID: String, expectedRevision: String,
        undo: BL6SettingsReplayRecord?,
        makeReplayRecord: @Sendable (String, String) throws -> BL6SettingsReplayRecord
    ) throws -> BL6SettingsReplayRecord {
        try store.commitBL6SkillEnablement(
            skillID: skillID, enabled: enabled, visibleTo: scope,
            profileID: profileID, expectedRevision: expectedRevision,
            undo: undo, makeReplayRecord: makeReplayRecord)
    }

    /// Value-only status for settings projections; source bytes never leave
    /// the runtime store and no second lifecycle authority is introduced.
    func state(for settingsID: String) -> SkillEnablementState? {
        guard let skillID = Self.appSkillID(from: settingsID),
              let skill = store.allSkills().first(where: { $0.id == skillID }) else {
            return nil
        }
        guard let receipt = store.lifecycleReceipt(for: skillID) else { return .pending }
        if !skill.isEnabled, receipt.enablementState == .active { return .pending }
        return receipt.enablementState
    }

    private static func lifecycleAllowsEnablement(for skillID: String, in store: SkillStore) -> Bool {
        guard let receipt = store.lifecycleReceipt(for: skillID),
              let content = store.rawContent(skillID) else { return false }
        return SkillLifecycle.isActivationValid(
            receipt,
            currentContentHash: SkillManifest.hash(content),
            scope: receipt.scope
        )
    }

    static func appSkillID(from settingsID: String) -> String? {
        let prefix = "app:"
        guard settingsID.hasPrefix(prefix) else { return nil }
        let skillID = String(settingsID.dropFirst(prefix.count))
        return skillID.isEmpty ? nil : skillID
    }
}
