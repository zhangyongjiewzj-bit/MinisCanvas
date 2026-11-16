import Foundation

/// A stable location for one persisted transcript message.
public struct SessionMessageLocator: Sendable {
    public let sessionID: String
    public let messageID: String
    public let transcriptIndex: Int
    public let role: LLMMessage.Role
    public let snippet: String
    public let matchedText: String?

    public var id: String { "\(sessionID)#\(messageID)" }

    public init(
        sessionID: String,
        messageID: String,
        transcriptIndex: Int,
        role: LLMMessage.Role,
        snippet: String,
        matchedText: String?
    ) {
        self.sessionID = sessionID
        self.messageID = messageID
        self.transcriptIndex = transcriptIndex
        self.role = role
        self.snippet = snippet
        self.matchedText = matchedText
    }
}

public enum SessionThreadActivity: String, Codable, Equatable, Hashable, Sendable {
    case idle
    case running
    case failed
}

/// Read-only discovery projection for a persisted thread.
///
/// `running` and `failed` are intentionally not inferred from session files.
/// They remain available as explicit caller-supplied activity facts for the
/// later live ChatStore projection.
public struct SessionThreadState: Identifiable, Equatable, Hashable, Sendable {
    public let sessionID: String
    public let title: String
    public let updatedAt: Date
    public let messageCount: Int
    public let unreadCount: Int
    public let isArchived: Bool
    public let activity: SessionThreadActivity
    public let lastMessageID: String?
    public let lastMessageSnippet: String?

    public var id: String { sessionID }
    public var isUnread: Bool { unreadCount > 0 }

    public init(
        sessionID: String,
        title: String,
        updatedAt: Date,
        messageCount: Int,
        unreadCount: Int,
        isArchived: Bool,
        activity: SessionThreadActivity = .idle,
        lastMessageID: String?,
        lastMessageSnippet: String?
    ) {
        self.sessionID = sessionID
        self.title = title
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.unreadCount = max(0, unreadCount)
        self.isArchived = isArchived
        self.activity = activity
        self.lastMessageID = lastMessageID
        self.lastMessageSnippet = lastMessageSnippet
    }
}

/// Deterministic transcript search and exact message-ID locator.
public struct SessionHistoryLocator: Sendable {
    public let snippetLimit: Int

    public init(snippetLimit: Int = 160) {
        self.snippetLimit = max(1, snippetLimit)
    }

    public func messageID(
        for message: LLMMessage,
        transcriptIndex: Int
    ) -> String {
        Compactor.stableMessageID(message, transcriptIndex: transcriptIndex)
    }

    public func locate(
        session: ChatSession,
        messageID: String
    ) -> SessionMessageLocator? {
        guard !messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        for (index, message) in session.messages.enumerated()
        where self.messageID(for: message, transcriptIndex: index) == messageID {
            return makeLocator(
                sessionID: session.id,
                message: message,
                transcriptIndex: index,
                query: nil
            )
        }
        return nil
    }

    public func search(
        session: ChatSession,
        query: String,
        limit: Int = 20
    ) -> [SessionMessageLocator] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, limit > 0 else { return [] }

        return session.messages.enumerated().compactMap { index, message in
            guard message.content.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil else {
                return nil
            }
            return makeLocator(
                sessionID: session.id,
                message: message,
                transcriptIndex: index,
                query: needle
            )
        }
        .prefix(limit)
        .map { $0 }
    }

    public func threadState(
        for session: ChatSession,
        unreadCount: Int,
        isArchived: Bool,
        activity: SessionThreadActivity = .idle
    ) -> SessionThreadState {
        let lastIndex = session.messages.indices.last
        let lastMessage = lastIndex.map { session.messages[$0] }
        return SessionThreadState(
            sessionID: session.id,
            title: session.title,
            updatedAt: session.updatedAt,
            messageCount: session.messages.count,
            unreadCount: unreadCount,
            isArchived: isArchived,
            activity: activity,
            lastMessageID: lastIndex.map {
                messageID(for: session.messages[$0], transcriptIndex: $0)
            },
            lastMessageSnippet: lastMessage.map { snippet(for: $0.content) }
        )
    }

    private func makeLocator(
        sessionID: String,
        message: LLMMessage,
        transcriptIndex: Int,
        query: String?
    ) -> SessionMessageLocator {
        let matchedText: String?
        if let query,
           let range = message.content.range(
               of: query,
               options: [.caseInsensitive, .diacriticInsensitive]
           ) {
            matchedText = String(message.content[range])
        } else {
            matchedText = nil
        }
        return SessionMessageLocator(
            sessionID: sessionID,
            messageID: messageID(for: message, transcriptIndex: transcriptIndex),
            transcriptIndex: transcriptIndex,
            role: message.role,
            snippet: snippet(for: message.content),
            matchedText: matchedText
        )
    }

    private func snippet(for content: String) -> String {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > snippetLimit else { return normalized }
        return String(normalized.prefix(snippetLimit))
    }
}

public extension SessionManager {
    /// Search active and optionally archived transcripts by exact message text.
    func searchHistory(
        query: String,
        sessionID: String? = nil,
        includeArchived: Bool = true,
        limit: Int = 20,
        locator: SessionHistoryLocator = SessionHistoryLocator()
    ) -> [SessionMessageLocator] {
        guard limit > 0 else { return [] }
        let sessions: [ChatSession]
        if let sessionID {
            sessions = [loadSessionIncludingArchived(id: sessionID)].compactMap { $0 }
        } else {
            let active = store.listSessions()
            let archived = includeArchived ? archivedSessions() : []
            sessions = active + archived
        }

        var results: [SessionMessageLocator] = []
        for session in sessions where includeArchived || store.loadSession(id: session.id) != nil {
            results.append(contentsOf: locator.search(
                session: session,
                query: query,
                limit: limit - results.count
            ))
            if results.count >= limit { break }
        }
        return results
    }

    /// Locate one exact stable message ID in active or archived history.
    func locateHistoryMessage(
        sessionID: String,
        messageID: String,
        includeArchived: Bool = true,
        locator: SessionHistoryLocator = SessionHistoryLocator()
    ) -> SessionMessageLocator? {
        guard let session = includeArchived
            ? loadSessionIncludingArchived(id: sessionID)
            : store.loadSession(id: sessionID)
        else {
            return nil
        }
        return locator.locate(session: session, messageID: messageID)
    }

    /// Discover persisted thread state without guessing live running/failed facts.
    func discoverThreadStates(
        includeArchived: Bool = true,
        locator: SessionHistoryLocator = SessionHistoryLocator()
    ) -> [SessionThreadState] {
        let active = listWithStats().map {
            locator.threadState(
                for: $0.session,
                unreadCount: $0.unreadCount,
                isArchived: false
            )
        }
        guard includeArchived else { return active }
        let archived = archivedSessions().map {
            locator.threadState(
                for: $0,
                unreadCount: badgeStore.unreadCount(for: $0.id),
                isArchived: true
            )
        }
        return (active + archived).sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.sessionID < $1.sessionID
        }
    }
}
