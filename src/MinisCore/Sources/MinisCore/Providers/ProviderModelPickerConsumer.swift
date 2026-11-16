import Foundation

/// Consumer bridge between persisted readiness records and the chat picker.
///
/// The existing `ChatModelPickerProjection` remains the diagnostic directory;
/// this bridge is the selection-facing view. It applies K31's catalog health
/// decision before exposing an item, while retaining default/persisted
/// references even when their catalog entry is temporarily unavailable.
public struct ProviderModelPickerConsumer: Codable, Equatable, Hashable, Sendable {
    public let projection: ChatModelPickerProjection
    public let catalog: ProviderModelSelectionCatalog

    public init(
        records: [ProviderReadinessPersistenceRecord],
        catalog: ProviderModelSelectionCatalog
    ) {
        self.projection = ChatModelPickerProjection(records: records)
        self.catalog = catalog
    }

    /// Convenience for callers that only have readiness records. A record is
    /// configured when it exists; callers with credential/version information
    /// should use the catalog initializer above.
    public init(
        records: [ProviderReadinessPersistenceRecord],
        defaultSelection: ProviderModelSelectionReference? = nil,
        persistedSelection: ProviderModelSelectionReference? = nil
    ) {
        // Use the same newest-per-provider/model projection as the chat
        // surface.  Feeding historical observations directly into the
        // catalog would manufacture an alias ambiguity and hide a currently
        // passed model after a later readiness retry.
        let latest = ChatModelPickerProjection(records: records)
        let current = latest.items + latest.pending
        self.init(
            records: records,
            catalog: ProviderModelSelectionCatalog(
                candidates: current.map {
                    ProviderModelSelectionCandidate(
                        providerID: $0.providerID,
                        modelID: $0.modelID,
                        isConfigured: true,
                        status: $0.status,
                        readinessState: $0.readinessState
                    )
                },
                defaultSelection: defaultSelection,
                persistedSelection: persistedSelection
            )
        )
    }

    /// Only items passing both the existing receipt gate and the catalog
    /// health gate reach the model picker.
    public var selectableItems: [ChatModelPickerItem] {
        projection.items.filter { item in
            guard item.isSelectable else { return false }
            return catalog.decision(for: ProviderModelSelectionReference(
                providerID: item.providerID,
                modelID: item.modelID
            )).isSelectable
        }
    }

    /// All applied and pending rows, retained for a settings-side recovery
    /// action.  Only `selectableItems` is a send/compose authorization.
    public var allItems: [ChatModelPickerItem] {
        projection.items + projection.pending
    }

    public func decision(
        for reference: ProviderModelSelectionReference
    ) -> ProviderModelSelectionDecision {
        let decision = catalog.decision(for: reference)
        guard decision.isSelectable else { return decision }
        guard let resolved = decision.resolvedReference,
              projection.item(
                  providerID: resolved.providerID,
                  modelID: resolved.modelID
              )?.isSelectable == true else {
            return ProviderModelSelectionDecision(
                requested: reference,
                candidate: decision.candidate,
                resolvedReference: nil,
                availability: .missing,
                reason: .catalogEntryMissing
            )
        }
        return decision
    }

    /// Resolves a persisted preference first, then the global default.  A
    /// failed preferred decision is returned rather than silently replaced so
    /// the UI can explain the recovery path and preserve user intent.
    public func resolve(
        preferred: ProviderModelSelectionReference?,
        fallback: ProviderModelSelectionReference?
    ) -> ProviderModelSelectionDecision? {
        if let preferred {
            return decision(for: preferred)
        }
        return fallback.map(decision(for:))
    }

    public var retainedDefaultSelection: ProviderModelSelectionReference? {
        catalog.retainedDefaultSelection
    }

    public var retainedPersistedSelection: ProviderModelSelectionReference? {
        catalog.retainedPersistedSelection
    }

    public var defaultDecision: ProviderModelSelectionDecision? {
        catalog.defaultSelection.map(decision(for:))
    }

    public var persistedDecision: ProviderModelSelectionDecision? {
        catalog.persistedSelection.map(decision(for:))
    }

    public func item(providerID: String, modelID: String) -> ChatModelPickerItem? {
        guard let projected = projection.item(providerID: providerID, modelID: modelID),
              projected.isSelectable else { return nil }
        return selectableItems.first { $0.id == projected.id }
    }

    public func isSelectable(providerID: String, modelID: String) -> Bool {
        item(providerID: providerID, modelID: modelID) != nil
    }
}

/// Secret-free durable catalog for the provider/model picker.
///
/// Writes use Foundation's atomic replacement option. A corrupt snapshot is
/// quarantined and reopened as an empty catalog; a successor rebind clears
/// authorization and readiness instead of silently inheriting it.
public final class ProviderModelSelectionStore: @unchecked Sendable {
    public enum RecoveryState: String, Codable, Hashable, Sendable {
        case new
        case loaded
        case quarantinedCorrupt
    }

    private struct Snapshot: Codable {
        let schemaVersion: Int
        let catalog: ProviderModelSelectionCatalog
    }

    public static let schemaVersion = 1
    public let fileURL: URL

    private let lock = NSLock()
    private let fileManager: FileManager
    private var storedCatalog: ProviderModelSelectionCatalog
    private var storedRecoveryState: RecoveryState

    public init(directoryURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = directoryURL.appendingPathComponent("provider-model-selection.json")
        self.storedCatalog = ProviderModelSelectionCatalog(candidates: [])
        self.storedRecoveryState = .new
        load()
    }

    public var catalog: ProviderModelSelectionCatalog {
        lock.lock()
        defer { lock.unlock() }
        return storedCatalog
    }

    public var recoveryState: RecoveryState {
        lock.lock()
        defer { lock.unlock() }
        return storedRecoveryState
    }

    /// Reopens the same snapshot through a fresh store instance, which is
    /// useful to make persistence boundaries explicit at the consumer edge.
    public func reopened() -> ProviderModelSelectionStore {
        ProviderModelSelectionStore(directoryURL: fileURL.deletingLastPathComponent(), fileManager: fileManager)
    }

    @discardableResult
    public func replace(_ catalog: ProviderModelSelectionCatalog) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard persist(catalog) else { return false }
        storedCatalog = catalog
        storedRecoveryState = .loaded
        return true
    }

    /// Atomically records a provider-qualified conversation choice while
    /// retaining the catalog, global default, and credential-version fence.
    /// Passing nil clears only the persisted choice.
    @discardableResult
    public func persistSelection(
        _ reference: ProviderModelSelectionReference?
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard reference == nil || reference?.isValid == true else { return false }
        let next = ProviderModelSelectionCatalog(
            candidates: storedCatalog.candidates,
            defaultSelection: storedCatalog.defaultSelection,
            persistedSelection: reference,
            activeCredentialVersions: storedCatalog.activeCredentialVersions
        )
        guard persist(next) else { return false }
        storedCatalog = next
        storedRecoveryState = .loaded
        return true
    }

    /// Atomically persists a rebind and invalidates the old provider's
    /// readiness/credential authorization. The operation is a no-op when the
    /// old identity is absent or the identities are invalid/equal.
    @discardableResult
    public func rebindProvider(providerID: String, to successorProviderID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard storedCatalog.containsProvider(providerID) else { return false }
        let next = storedCatalog.rebound(providerID: providerID, to: successorProviderID)
        guard next != storedCatalog, persist(next) else { return false }
        storedCatalog = next
        storedRecoveryState = .loaded
        return true
    }

    private func load() {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard fileManager.fileExists(atPath: fileURL.path) else { return }
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.schemaVersion == Self.schemaVersion else { throw CocoaError(.fileReadCorruptFile) }
            storedCatalog = snapshot.catalog
            storedRecoveryState = .loaded
        } catch {
            quarantineCorruptSnapshot()
            storedCatalog = ProviderModelSelectionCatalog(candidates: [])
            storedRecoveryState = .quarantinedCorrupt
        }
    }

    private func persist(_ catalog: ProviderModelSelectionCatalog) -> Bool {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Snapshot(schemaVersion: Self.schemaVersion, catalog: catalog))
            try data.write(to: fileURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    private func quarantineCorruptSnapshot() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let suffix = UUID().uuidString.lowercased()
        let quarantineURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("provider-model-selection.corrupt-\(suffix).json")
        try? fileManager.moveItem(at: fileURL, to: quarantineURL)
    }
}
