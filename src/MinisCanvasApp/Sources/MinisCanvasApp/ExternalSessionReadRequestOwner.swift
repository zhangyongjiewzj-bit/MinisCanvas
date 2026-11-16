import Foundation
import MinisCore

/// Owns only the presentation request identity. Authorization remains with the
/// existing composition and adapter; a late authorized response cannot publish
/// into a different source or a newer request in the ledger card.
@MainActor
final class ExternalSessionReadRequestOwner {
    enum Kind: Equatable {
        case discovery
        case read
    }

    struct Envelope: Equatable {
        let kind: Kind
        let sourceID: ExternalSessionSourceID
        let threadID: ExternalSessionThreadID?
        let cursor: ExternalSessionCursorV1
        let generation: UInt64
    }

    private(set) var sourceID: ExternalSessionSourceID?
    private(set) var threadID: ExternalSessionThreadID?
    private var generation: UInt64 = 0
    private var active: Envelope?
    private var isOpen = true

    func open(sourceID: ExternalSessionSourceID?) {
        isOpen = true
        switchSource(sourceID)
    }

    func close() {
        isOpen = false
        invalidate()
    }

    func switchSource(_ sourceID: ExternalSessionSourceID?) {
        self.sourceID = sourceID
        threadID = nil
        invalidate()
    }

    func selectThread(_ threadID: ExternalSessionThreadID?) {
        self.threadID = threadID
        invalidate()
    }

    func beginDiscovery(sourceID: ExternalSessionSourceID, cursor: ExternalSessionCursorV1) -> Envelope? {
        guard isOpen, self.sourceID == sourceID else { return nil }
        if cursor == .beginning { threadID = nil }
        return begin(kind: .discovery, sourceID: sourceID, threadID: nil, cursor: cursor)
    }

    func beginRead(
        sourceID: ExternalSessionSourceID,
        threadID: ExternalSessionThreadID,
        cursor: ExternalSessionCursorV1
    ) -> Envelope? {
        guard isOpen, self.sourceID == sourceID else { return nil }
        if cursor == .beginning { self.threadID = threadID }
        guard self.threadID == threadID else { return nil }
        return begin(kind: .read, sourceID: sourceID, threadID: threadID, cursor: cursor)
    }

    func mayPublish(
        _ envelope: Envelope,
        selectedSourceID: ExternalSessionSourceID?,
        displayedThreadID: ExternalSessionThreadID?,
        expectedCursor: ExternalSessionCursorV1?
    ) -> Bool {
        guard isOpen, active == envelope,
              sourceID == envelope.sourceID,
              selectedSourceID == envelope.sourceID else { return false }
        switch envelope.kind {
        case .discovery:
            return envelope.cursor == .beginning || expectedCursor == envelope.cursor
        case .read:
            guard threadID == envelope.threadID else { return false }
            return envelope.cursor == .beginning
                || (displayedThreadID == envelope.threadID && expectedCursor == envelope.cursor)
        }
    }

    private func begin(
        kind: Kind,
        sourceID: ExternalSessionSourceID,
        threadID: ExternalSessionThreadID?,
        cursor: ExternalSessionCursorV1
    ) -> Envelope {
        generation &+= 1
        let envelope = Envelope(
            kind: kind, sourceID: sourceID, threadID: threadID,
            cursor: cursor, generation: generation
        )
        active = envelope
        return envelope
    }

    private func invalidate() {
        generation &+= 1
        active = nil
    }
}
