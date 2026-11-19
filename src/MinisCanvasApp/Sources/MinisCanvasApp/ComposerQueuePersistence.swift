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
                // 首次运行：根目录可能已被别的模块按 0755 建出，存储层按约定拒绝读取；
                // 但草稿目录还不存在，磁盘上没有可恢复、需要保住原件的队列文件，按空队列处理。
                // 草稿目录存在时照旧报不可读并锁住队列，存储层的权限检查不变。
                if !FileManager.default.fileExists(atPath: store.draftsDirectory.path) { return [] }
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
