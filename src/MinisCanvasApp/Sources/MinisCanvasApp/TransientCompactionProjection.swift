import Foundation
import MinisCore

/// The non-persistent chat uses the same verified model result while keeping
/// its visible source unchanged. A later edit invalidates this projection.
struct TransientCompactionProjection: Sendable {
    let source: [ChatMessageUI]
    let messages: [ChatMessageUI]

    func applying(to history: [ChatMessageUI]) -> [ChatMessageUI]? {
        guard history.count >= source.count,
              Array(history.prefix(source.count)) == source else { return nil }
        return messages + Array(history.dropFirst(source.count))
    }
}

extension ChatStore {
    func providerHistoryApplyingTransientCompaction(
        _ history: [ChatMessageUI], sessionID: UUID?
    ) -> [ChatMessageUI] {
        guard sessionStore == nil, let sessionID,
              let projection = transientCompactionProjections[sessionID] else { return history }
        guard let projected = projection.applying(to: history) else {
            transientCompactionProjections.removeValue(forKey: sessionID)
            return history
        }
        return projected
    }
}
