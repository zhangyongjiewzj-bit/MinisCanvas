import Foundation

/// The UI-owned scroll fact source for a transcript.
///
/// ChatStore owns message persistence and streaming writeback. This type owns only
/// the user's reading intent, so transcript updates cannot silently take history
/// reading away from the user.
enum ChatTranscriptScrollEvent: Equatable {
    case viewport(isNearBottom: Bool)
    case userMessageAppended
    case assistantMessageAppended
    case streamContentChanged
    case streamCancelled
    case retryRequested
    case resumeFollowing
}

enum ChatTranscriptScrollAction: Equatable {
    case none
    case followBottom
    case preserveHistory
    case showNewMessages(count: Int)
}

/// Identity for the transcript viewport that emitted a scroll event.
///
/// Session UUID alone is insufficient when a session is removed and restored,
/// so every reset advances the generation as well.  A callback captured before
/// the reset can therefore be ignored without affecting the new session.
struct ChatTranscriptScrollIdentity: Equatable, Hashable {
    let sessionID: UUID?
    let generation: UInt64
}

struct ChatTranscriptScrollState: Equatable {
    private(set) var isNearBottom = true
    private(set) var isFollowing = true
    private(set) var pendingNewMessageCount = 0
    private(set) var identity = ChatTranscriptScrollIdentity(sessionID: nil, generation: 0)
    /// Only history positions need restoring; sessions left at the bottom keep following.
    private var historyOffsetBySession: [UUID: Double] = [:]

    var restorationOffset: Double? {
        guard let sessionID = identity.sessionID else { return nil }
        return historyOffsetBySession[sessionID]
    }

    mutating func resetForSession(_ sessionID: UUID? = nil) {
        identity = ChatTranscriptScrollIdentity(
            sessionID: sessionID,
            generation: identity.generation &+ 1
        )
        let restoringHistory = sessionID.flatMap { historyOffsetBySession[$0] } != nil
        isNearBottom = !restoringHistory
        isFollowing = !restoringHistory
        pendingNewMessageCount = 0
    }

    /// Record the native outer viewport, fenced by the generation that emitted it.
    /// A viewport created during a session switch must not replace another session's fact.
    @discardableResult
    mutating func recordViewport(
        isNearBottom: Bool,
        verticalOffset: Double,
        identity eventIdentity: ChatTranscriptScrollIdentity
    ) -> ChatTranscriptScrollAction {
        guard eventIdentity == identity, verticalOffset.isFinite else { return .none }
        if let sessionID = identity.sessionID {
            if isNearBottom {
                historyOffsetBySession.removeValue(forKey: sessionID)
            } else {
                historyOffsetBySession[sessionID] = max(0, verticalOffset)
            }
        }
        return apply(.viewport(isNearBottom: isNearBottom), identity: eventIdentity)
    }

    mutating func apply(
        _ event: ChatTranscriptScrollEvent,
        identity eventIdentity: ChatTranscriptScrollIdentity? = nil
    ) -> ChatTranscriptScrollAction {
        guard eventIdentity == nil || eventIdentity == identity else { return .none }

        switch event {
        case let .viewport(isNearBottom):
            let wasFollowing = self.isFollowing
            self.isNearBottom = isNearBottom
            self.isFollowing = isNearBottom
            if isNearBottom {
                pendingNewMessageCount = 0
            }
            return wasFollowing == isFollowing && isNearBottom == false
                ? .preserveHistory
                : (isNearBottom ? .followBottom : .preserveHistory)

        case .userMessageAppended:
            if let sessionID = identity.sessionID {
                historyOffsetBySession.removeValue(forKey: sessionID)
            }
            isNearBottom = true
            isFollowing = true
            pendingNewMessageCount = 0
            return .followBottom

        case .assistantMessageAppended:
            guard isFollowing else {
                pendingNewMessageCount += 1
                return .showNewMessages(count: pendingNewMessageCount)
            }
            return .followBottom

        case .streamContentChanged, .streamCancelled, .retryRequested:
            return isFollowing ? .followBottom : .preserveHistory

        case .resumeFollowing:
            if let sessionID = identity.sessionID {
                historyOffsetBySession.removeValue(forKey: sessionID)
            }
            isNearBottom = true
            isFollowing = true
            pendingNewMessageCount = 0
            return .followBottom
        }
    }
}

/// A stable UI identity for an attachment slot.
///
/// ChatStore may replace a file placeholder with a data-bearing attachment while
/// reading asynchronously. The source path and message slot stay stable across
/// that replacement; the model UUID does not.
struct ChatAttachmentRenderItem: Identifiable, Equatable {
    let id: String
    let attachment: ChatAttachment

    init(messageID: UUID, slot: Int, attachment: ChatAttachment) {
        let source = attachment.fileURL ?? attachment.fileName
        id = "\(messageID.uuidString):\(slot):\(source)"
        self.attachment = attachment
    }
}
