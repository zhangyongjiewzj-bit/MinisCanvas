import Foundation
import MinisCore

/// Production conversation-side consumer for the provider/model directory.
///
/// The picker owns only transient preview state.  `ChatStore` remains the
/// composer/runtime authority, while MinisCore remains the readiness and
/// persistence authority.  This prevents a row that is merely discovered or
/// stale from becoming a generation route.
@MainActor
struct ConversationModelPickerConsumer {
    enum SelectionMode: String, Equatable, Sendable {
        case inheritedGlobal
        case explicitConversationOverride
    }

    struct Row: Identifiable, Equatable, Sendable {
        let id: String
        let providerID: String
        let modelID: String
        let statusLabel: String
        let recoveryAction: ProviderModelSelectionRecoveryAction
        let isSelectable: Bool
        let accessibilityIdentifier: String
    }

    let chat: ChatStore
    private(set) var selectionStore: ProviderModelSelectionStore?
    private(set) var previewedReference: ProviderModelSelectionReference?

    init(
        chat: ChatStore,
        selectionStore: ProviderModelSelectionStore? = nil
    ) {
        self.chat = chat
        self.selectionStore = selectionStore
        self.previewedReference = nil
    }

    /// Current readiness view.  Rebuilding this on every access is deliberate:
    /// readiness records can change after a settings check without reopening
    /// the conversation window.
    private var coreConsumer: MinisCore.ProviderModelPickerConsumer {
        guard let store = chat.providerReadinessStore else {
            return MinisCore.ProviderModelPickerConsumer(records: [])
        }
        if let selectionStore {
            return MinisCore.ProviderModelPickerConsumer(
                records: store.records,
                catalog: selectionStore.catalog
            )
        }
        return MinisCore.ProviderModelPickerConsumer(records: store.records)
    }

    var rows: [Row] {
        let consumer = coreConsumer
        return consumer.allItems.compactMap { item in
            let reference = ProviderModelSelectionReference(
                providerID: item.providerID,
                modelID: item.modelID
            )
            let decision = consumer.decision(for: reference)
            return Row(
                id: item.id,
                providerID: item.providerID,
                modelID: item.modelID,
                statusLabel: decision.statusLabel,
                recoveryAction: decision.recoveryAction,
                isSelectable: decision.isSelectable,
                accessibilityIdentifier: Self.accessibilityIdentifier(
                    providerID: item.providerID,
                    modelID: item.modelID
                )
            )
        }
    }

    var currentReference: ProviderModelSelectionReference? {
        guard let providerID = currentProviderID,
              let modelID = chat.selectedModelID,
              !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return ProviderModelSelectionReference(
            providerID: ProviderReadinessRevision.canonicalProviderID(providerID),
            modelID: ChatStore.canonicalModelID(modelID)
        )
    }

    var currentDecision: ProviderModelSelectionDecision? {
        currentReference.map(coreConsumer.decision(for:))
    }

    var selectionMode: SelectionMode {
        guard let activeID = chat.activeSessionID,
              let session = chat.sessions.first(where: { $0.id == activeID }) else {
            return .inheritedGlobal
        }
        return session.providerTypeRaw != nil || session.modelID != nil
            ? .explicitConversationOverride
            : .inheritedGlobal
    }

    /// Preview never mutates the composer.  The resolved reference is stored
    /// so alias recovery cannot accidentally confirm the old alias.
    @discardableResult
    mutating func preview(providerID: String, modelID: String) -> Bool {
        let requested = ProviderModelSelectionReference(
            providerID: providerID,
            modelID: modelID
        )
        guard requested.isValid,
              let decision = Optional(coreConsumer.decision(for: requested)),
              decision.isSelectable,
              let resolved = decision.resolvedReference else {
            previewedReference = nil
            return false
        }
        previewedReference = resolved
        return true
    }

    mutating func cancelPreview() {
        previewedReference = nil
    }

    /// Confirmation crosses the single runtime boundary in ChatStore.  A
    /// failed apply leaves both the current selection and the preview intact.
    @discardableResult
    mutating func confirmPreview() -> Bool {
        guard let reference = previewedReference else { return false }
        let previousCatalog = selectionStore?.catalog
        if let selectionStore,
           !selectionStore.persistSelection(reference) {
            return false
        }
        guard chat.applyChatModel(
            providerID: reference.providerID,
            modelID: reference.modelID
        ) else {
            if let previousCatalog,
               let selectionStore {
                _ = selectionStore.replace(previousCatalog)
            }
            return false
        }
        previewedReference = nil
        return true
    }

    /// Restoring an inherited/global choice is only safe when the active
    /// conversation has no explicit override.  The composition root supplies
    /// its canonical global restore operation; this consumer never rewrites
    /// session persistence itself.
    @discardableResult
    mutating func restoreGlobal(using restore: () -> Bool) -> Bool {
        guard selectionMode == .inheritedGlobal else { return false }
        guard restore() else { return false }
        previewedReference = nil
        return true
    }

    /// Rebinds the durable provider identity and immediately reopens the
    /// consumer from the same store.  The Core store invalidates old health
    /// and credential authorization; no secret crosses this boundary.
    @discardableResult
    mutating func rebindProvider(
        providerID: String,
        to successorProviderID: String
    ) -> Bool {
        guard let selectionStore,
              selectionStore.rebindProvider(
                  providerID: providerID,
                  to: successorProviderID
              ) else {
            return false
        }
        // Reopen from disk so no pre-rebind in-memory catalog can leak into
        // the next picker presentation.
        self.selectionStore = selectionStore.reopened()
        previewedReference = nil
        return true
    }

    /// A fresh value models closing and reopening the picker while retaining
    /// the same chat/runtime and durable selection store.
    func reopened() -> ConversationModelPickerConsumer {
        ConversationModelPickerConsumer(
            chat: chat,
            selectionStore: selectionStore?.reopened()
        )
    }

    private var currentProviderID: String? {
        if let custom = chat.selectedCustomProvider {
            return custom.name
        }
        return chat.selectedProviderType?.rawValue
    }

    private static func accessibilityIdentifier(
        providerID: String,
        modelID: String
    ) -> String {
        func component(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let safe = trimmed.replacingOccurrences(
                of: "[^A-Za-z0-9._-]+",
                with: "_",
                options: .regularExpression
            )
            return safe.isEmpty ? "unknown" : safe
        }
        return "conversation.model-picker.\(component(providerID)).\(component(modelID))"
    }
}
