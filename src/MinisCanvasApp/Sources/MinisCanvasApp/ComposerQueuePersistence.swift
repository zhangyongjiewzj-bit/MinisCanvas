import Foundation

/// The queue owns the same payload as the composer draft. Stable IDs survive
/// restart so editing/deleting a row cannot accidentally select another row.
struct PersistedComposerQueueItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let sessionID: UUID
    var text: String
    var attachments: [ChatAttachment]
    var pastedDrafts: [PastedTextDraft]

    init(id: UUID = UUID(), sessionID: UUID, text: String,
         attachments: [ChatAttachment], pastedDrafts: [PastedTextDraft]) {
        self.id = id
        self.sessionID = sessionID
        self.text = text
        self.attachments = attachments
        self.pastedDrafts = pastedDrafts
    }
}

enum ComposerQueuePersistence {
    static let key = "composerQueue"

    enum Failure: Error, Equatable {
        case unreadable
        case unsupportedVersion(Int)
        case writeFailed
    }

    private struct Envelope: Codable {
        var version: Int = 1
        let items: [PersistedComposerQueueItem]
    }

    static func load(using store: DraftStore) throws -> [PersistedComposerQueueItem] {
        guard let payload = store.load(key: key) else {
            if store.lastLoadError(for: key) != nil || store.lastIOError(for: key) != nil {
                throw Failure.unreadable
            }
            return []
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: payload)
        guard envelope.version == 1 else { throw Failure.unsupportedVersion(envelope.version) }
        return envelope.items
    }

    /// Queue mutations commit immediately; the composer never needs to wait
    /// for the ordinary typing debounce before it can safely clear its input.
    static func save(_ items: [PersistedComposerQueueItem], using store: DraftStore) throws {
        let payload = try JSONEncoder().encode(Envelope(items: items))
        store.scheduleSave(key: key, payload: payload)
        guard store.flushNow(key: key) else { throw Failure.writeFailed }
    }
}
