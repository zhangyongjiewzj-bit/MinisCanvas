import Foundation
import MinisCore

/// A typed view over the existing scoped MemoryStore owner. Registration in
/// the agent catalog and authorization of a settings call belong to Stage C;
/// this adapter grants neither and does not persist an independent settings
/// record or undo protocol.
@MainActor
enum MemoryStoreTypedCatalogAdapter {
    enum Failure: Error, Equatable {
        case invalidScope
        case unknownSetting(String)
        case invalidValue(String)
        case stalePreview
        case undoUnsupported
    }

    struct Preview: Equatable {
        enum Change: Equatable {
            case edit(String)
            case tombstone
        }

        let settingID: String
        let scope: MemoryScope
        let before: MemoryFact
        let proposedValue: BL6SettingValue
        let change: Change
    }

    struct Effect: Equatable {
        let settingID: String
        let before: MemoryFact
        let after: MemoryFact
        let lifecycleReceipt: MemoryFactLifecycleReceipt?
    }


    struct UndoPreview: Equatable {
        let effect: Effect
        let scope: MemoryScope
        let predecessor: MemoryFact
    }

    static func settingID(for fact: MemoryFact) -> String {
        "memory.fact.\(fact.id)"
    }

    /// A missing/invalid scope never becomes a global memory query. Personal
    /// and temporary facts require principal/lifetime facts not present at this
    /// adapter boundary, so they cannot be projected here.
    static func snapshot(from center: SettingsCenter) throws -> [String: BL6SettingValue] {
        guard let scope = center.memoryScopeProvider?(), scope.isValid else {
            throw Failure.invalidScope
        }
        return Dictionary(uniqueKeysWithValues: try center.memoryStore.facts()
            .filter { isEditable($0, within: scope) }
            .map { (settingID(for: $0), value(for: $0)) })
    }

    static func preview(
        settingID: String,
        value proposed: BL6SettingValue,
        in center: SettingsCenter
    ) throws -> Preview {
        guard let scope = center.memoryScopeProvider?(), scope.isValid else {
            throw Failure.invalidScope
        }
        guard let fact = try center.memoryStore.facts().first(where: {
            Self.settingID(for: $0) == settingID && isEditable($0, within: scope)
        }) else {
            throw Failure.unknownSetting(settingID)
        }
        guard case .object(let fields) = proposed,
              case .text(let proposedText)? = fields["text"],
              case .toggle(let active)? = fields["active"] else {
            throw Failure.invalidValue(settingID)
        }
        var expectedFields: [String: BL6SettingValue]
        guard case .object(let liveFields) = value(for: fact) else {
            throw Failure.invalidValue(settingID)
        }
        expectedFields = liveFields
        expectedFields["text"] = .text(proposedText)
        expectedFields["active"] = .toggle(active)
        // This exact-object check makes scope, source/provenance, category,
        // revision, and chain metadata read-only. Omitted and extra fields
        // fail equally, so a model cannot invent a different owner/source.
        guard fields == expectedFields else { throw Failure.invalidValue(settingID) }

        let change: Preview.Change
        if active {
            guard !proposedText.isEmpty,
                  proposedText == proposedText.trimmingCharacters(in: .whitespacesAndNewlines),
                  proposedText != fact.text else {
                throw Failure.invalidValue(settingID)
            }
            change = .edit(proposedText)
        } else {
            guard proposedText == fact.text else { throw Failure.invalidValue(settingID) }
            change = .tombstone
        }
        return Preview(settingID: settingID, scope: scope, before: fact,
                       proposedValue: proposed, change: change)
    }

    /// A preview is data, not authority. Rebuild it against the current
    /// SettingsCenter scope and live Store before invoking its original write
    /// entry; a changed fact or session cannot consume an old preview.
    static func apply(
        _ preview: Preview, in center: SettingsCenter,
        makeSettingsReplayRecord: BL6MemoryReplayRecordFactory? = nil
    ) throws -> Effect {
        let current = try self.preview(
            settingID: preview.settingID, value: preview.proposedValue, in: center
        )
        guard current == preview else { throw Failure.stalePreview }
        switch preview.change {
        case .edit(let text):
            let revised = try center.commitMemoryFactEdit(
                id: preview.before.id, text: text, expected: preview.before,
                makeSettingsReplayRecord: makeSettingsReplayRecord
            )
            return Effect(settingID: preview.settingID, before: preview.before,
                          after: revised, lifecycleReceipt: nil)
        case .tombstone:
            let receipt = try center.memoryStore.tombstoneFact(
                id: preview.before.id, reason: "用户在记忆设置中停用",
                makeSettingsReplayRecord: makeSettingsReplayRecord
            )
            center.reloadStorage()
            guard let after = try center.memoryStore.facts().first(where: {
                $0.id == preview.before.id && $0.lifecycleState == .tombstoned
            }) else {
                throw Failure.stalePreview
            }
            return Effect(settingID: preview.settingID, before: preview.before,
                          after: after, lifecycleReceipt: receipt)
        }
    }


    /// Only a live edit successor can be undone through the existing revision
    /// rollback. A tombstone has no ordinary inverse; import/restore is a
    /// separate authorized operation and must never stand in for this undo.
    static func previewUndo(_ effect: Effect, in center: SettingsCenter) throws -> UndoPreview {
        guard effect.lifecycleReceipt == nil,
              effect.after.id != effect.before.id,
              effect.after.supersedesFactID == effect.before.id,
              effect.after.revision == effect.before.revision + 1 else {
            throw Failure.undoUnsupported
        }
        guard let scope = center.memoryScopeProvider?(), scope.isValid,
              effect.before.memoryScope == scope,
              isEditable(effect.after, within: scope),
              effect.settingID == settingID(for: effect.before) else {
            throw Failure.invalidScope
        }
        let facts = try center.memoryStore.facts()
        guard facts.first(where: { $0.id == effect.after.id }) == effect.after,
              let predecessor = facts.first(where: { $0.id == effect.before.id }),
              predecessor == supersededVersion(of: effect.before) else {
            throw Failure.stalePreview
        }
        return UndoPreview(effect: effect, scope: scope, predecessor: predecessor)
    }

    /// Owner-only Store call. The model-facing dispatcher must consume its
    /// own approval and durable replay record before invoking this entry.
    @discardableResult
    static func undo(
        _ preview: UndoPreview, in center: SettingsCenter,
        makeSettingsReplayRecord: BL6MemoryReplayRecordFactory? = nil
    ) throws -> MemoryFactLifecycleReceipt {
        guard try previewUndo(preview.effect, in: center) == preview else {
            throw Failure.stalePreview
        }
        let receipt = try center.memoryStore.rollbackRevision(
            expectedSuccessor: preview.effect.after,
            expectedPredecessor: preview.predecessor,
            reason: "用户在记忆设置中撤销编辑",
            makeSettingsReplayRecord: makeSettingsReplayRecord
        )
        center.reloadStorage()
        return receipt
    }

    private static func supersededVersion(of fact: MemoryFact) -> MemoryFact {
        MemoryFact(
            id: fact.id,
            text: fact.text,
            sourceSessionID: fact.sourceSessionID,
            createdAt: fact.createdAt,
            category: fact.category,
            memoryScope: fact.memoryScope,
            ownerUserID: fact.ownerUserID,
            visibility: fact.visibility,
            temporaryLifetimeID: fact.temporaryLifetimeID,
            sourceProposalID: fact.sourceProposalID,
            sourceRef: fact.sourceRef,
            contentDigest: fact.contentDigest,
            writeProvenance: fact.writeProvenance,
            revision: fact.revision,
            supersedesFactID: fact.supersedesFactID,
            lifecycleState: .superseded,
            activatedAt: fact.activatedAt
        )
    }

    private static func isEditable(_ fact: MemoryFact, within scope: MemoryScope) -> Bool {
        fact.lifecycleState == .active
            && fact.memoryScope == scope
            && (fact.visibility == nil || fact.visibility == .project)
    }

    private static func value(for fact: MemoryFact) -> BL6SettingValue {
        let scope = fact.memoryScope!
        var provenance: [String: BL6SettingValue] = [:]
        if let origin = fact.writeProvenance {
            provenance = [
                "actorID": .text(origin.actorID),
                "runID": .text(origin.runID),
                "triggerID": .text(origin.triggerID),
                "sourceID": .text(origin.sourceID),
                "submissionEpoch": .text(String(origin.submissionEpoch)),
                "sourceHash": .text(origin.sourceHash),
                "generation": .integer(origin.generation),
                "bindingDigest": .text(origin.bindingDigest)
            ]
        }
        return .object([
            "text": .text(fact.text),
            "active": .toggle(true),
            "category": .text(fact.category.rawValue),
            "revision": .integer(fact.revision),
            "supersedesFactID": .text(fact.supersedesFactID ?? ""),
            "scope": .object([
                "sessionID": .text(scope.sessionID),
                "projectID": .text(scope.projectID),
                "visibility": .text(fact.visibility?.rawValue ?? "")
            ]),
            "source": .object([
                "sourceSessionID": .text(fact.sourceSessionID),
                "sourceProposalID": .text(fact.sourceProposalID ?? ""),
                "sourceRef": .text(fact.sourceRef ?? ""),
                "typedProvenance": .object(provenance)
            ])
        ])
    }
}
