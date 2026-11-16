import Foundation

/// Fail-closed errors for the pure session-read pagination projection seam.
public enum SessionReadBoundedTextProjectionError: Error, Equatable, Sendable {
    case invalidUTF8
    case invalidBudget
    case invalidCursor
    case cursorSessionMismatch
    case cursorScopeMismatch
    case cursorRevisionMismatch
    case cursorTurnMismatch
    case cursorOutOfRange
}

/// The immutable pagination identity carried by a bounded session-read page.
///
/// Session, scope, revision, turn, offset and limit travel together. A caller
/// cannot silently reuse a continuation for another authorized target, turn,
/// snapshot, or page width.
public struct SessionReadPageCursor: Equatable, Sendable {
    public static let maximumLimit = 50

    public let sessionID: String
    public let scope: SessionReadScope
    public let revision: String
    public let turnID: Int
    public let offset: Int
    public let limit: Int

    public init(
        sessionID: String,
        scope: SessionReadScope,
        revision: String,
        turnID: Int,
        offset: Int,
        limit: Int
    ) throws {
        guard !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              turnID >= 0,
              offset >= 0,
              limit > 0,
              limit <= Self.maximumLimit else {
            throw SessionReadBoundedTextProjectionError.invalidCursor
        }
        self.sessionID = sessionID
        self.scope = scope
        self.revision = revision
        self.turnID = turnID
        self.offset = offset
        self.limit = limit
    }
}

/// A Unicode-safe bounded text value with explicit character and UTF-8 byte
/// accounting. Truncation walks Swift `Character` values, so a grapheme
/// cluster is either retained in full or omitted from the result.
public struct SessionReadBoundedTextProjection: Equatable, Sendable {
    public static let maximumCharacters = 8_000
    public static let maximumBytes = 64_000

    public let text: String
    public let sourceCharacterCount: Int
    public let sourceByteCount: Int
    public let characterCount: Int
    public let byteCount: Int
    public let maxCharacters: Int
    public let maxBytes: Int
    public let isTruncated: Bool

    public init(text: String, maxCharacters: Int, maxBytes: Int) throws {
        guard (0...Self.maximumCharacters).contains(maxCharacters),
              (0...Self.maximumBytes).contains(maxBytes) else {
            throw SessionReadBoundedTextProjectionError.invalidBudget
        }

        let sourceCharacterCount = text.count
        let sourceByteCount = text.utf8.count
        var projected = String()
        projected.reserveCapacity(min(sourceCharacterCount, maxCharacters))
        var projectedByteCount = 0
        var stoppedAtBudget = false

        for character in text {
            guard projected.count < maxCharacters else {
                stoppedAtBudget = true
                break
            }
            let characterText = String(character)
            let characterByteCount = characterText.utf8.count
            guard characterByteCount <= maxBytes - projectedByteCount else {
                stoppedAtBudget = true
                break
            }
            projected.append(character)
            projectedByteCount += characterByteCount
        }

        self.text = projected
        self.sourceCharacterCount = sourceCharacterCount
        self.sourceByteCount = sourceByteCount
        self.characterCount = projected.count
        self.byteCount = projectedByteCount
        self.maxCharacters = maxCharacters
        self.maxBytes = maxBytes
        self.isTruncated = stoppedAtBudget
            || projected.count != sourceCharacterCount
            || projectedByteCount != sourceByteCount
    }

    /// Decode only strict UTF-8. Replacement decoding is deliberately not
    /// used because an invalid byte sequence must not become a plausible
    /// session-read result.
    public init(utf8 data: Data, maxCharacters: Int, maxBytes: Int) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw SessionReadBoundedTextProjectionError.invalidUTF8
        }
        try self.init(text: text, maxCharacters: maxCharacters, maxBytes: maxBytes)
    }
}

/// Deterministic, bounded page projection for a caller-owned immutable
/// session snapshot. This pure seam is intentionally separate from the
/// existing SessionReadTool result envelope so the shared caller can adopt it
/// without widening authorization or persistence responsibilities here.
public struct SessionReadPageProjection: Equatable, Sendable {
    public let sessionID: String
    public let scope: SessionReadScope
    public let revision: String
    public let turnID: Int
    public let offset: Int
    public let limit: Int
    public let total: Int
    public let messages: [SessionReadBoundedTextProjection]
    public let hasMore: Bool
    public let nextOffset: Int?

    public var nextCursor: SessionReadPageCursor? {
        guard let nextOffset else { return nil }
        return try? SessionReadPageCursor(
            sessionID: sessionID,
            scope: scope,
            revision: revision,
            turnID: turnID,
            offset: nextOffset,
            limit: limit
        )
    }

    public static func project(
        messages: [String],
        sessionID: String,
        scope: SessionReadScope = .messages,
        revision: String,
        turnID: Int,
        offset: Int,
        limit: Int,
        maxCharacters: Int,
        maxBytes: Int
    ) throws -> SessionReadPageProjection {
        let cursor = try SessionReadPageCursor(
            sessionID: sessionID,
            scope: scope,
            revision: revision,
            turnID: turnID,
            offset: offset,
            limit: limit
        )
        return try project(
            messages: messages,
            cursor: cursor,
            maxCharacters: maxCharacters,
            maxBytes: maxBytes,
            expectedSessionID: sessionID,
            expectedScope: scope,
            expectedRevision: revision,
            expectedTurnID: turnID
        )
    }

    public static func project(
        messages: [String],
        cursor: SessionReadPageCursor,
        maxCharacters: Int,
        maxBytes: Int,
        expectedSessionID: String? = nil,
        expectedScope: SessionReadScope? = nil,
        expectedRevision: String? = nil,
        expectedTurnID: Int? = nil
    ) throws -> SessionReadPageProjection {
        guard cursor.scope == .messages else {
            throw SessionReadBoundedTextProjectionError.cursorScopeMismatch
        }
        if let expectedSessionID, expectedSessionID != cursor.sessionID {
            throw SessionReadBoundedTextProjectionError.cursorSessionMismatch
        }
        if let expectedScope, expectedScope != cursor.scope {
            throw SessionReadBoundedTextProjectionError.cursorScopeMismatch
        }
        if let expectedRevision, expectedRevision != cursor.revision {
            throw SessionReadBoundedTextProjectionError.cursorRevisionMismatch
        }
        if let expectedTurnID, expectedTurnID != cursor.turnID {
            throw SessionReadBoundedTextProjectionError.cursorTurnMismatch
        }
        guard cursor.offset <= messages.count else {
            throw SessionReadBoundedTextProjectionError.cursorOutOfRange
        }

        let remaining = messages.count - cursor.offset
        let pageCount = min(cursor.limit, remaining)
        let end = cursor.offset + pageCount
        let boundedMessages = try messages[cursor.offset..<end].map {
            try SessionReadBoundedTextProjection(
                text: $0,
                maxCharacters: maxCharacters,
                maxBytes: maxBytes
            )
        }
        let hasMore = end < messages.count
        return SessionReadPageProjection(
            sessionID: cursor.sessionID,
            scope: cursor.scope,
            revision: cursor.revision,
            turnID: cursor.turnID,
            offset: cursor.offset,
            limit: cursor.limit,
            total: messages.count,
            messages: boundedMessages,
            hasMore: hasMore,
            nextOffset: hasMore ? end : nil
        )
    }

    public static func project(
        utf8Messages: [Data],
        cursor: SessionReadPageCursor,
        maxCharacters: Int,
        maxBytes: Int,
        expectedSessionID: String? = nil,
        expectedScope: SessionReadScope? = nil,
        expectedRevision: String? = nil,
        expectedTurnID: Int? = nil
    ) throws -> SessionReadPageProjection {
        let decodedMessages = try utf8Messages.map { data in
            guard let message = String(data: data, encoding: .utf8) else {
                throw SessionReadBoundedTextProjectionError.invalidUTF8
            }
            return message
        }
        return try project(
            messages: decodedMessages,
            cursor: cursor,
            maxCharacters: maxCharacters,
            maxBytes: maxBytes,
            expectedSessionID: expectedSessionID,
            expectedScope: expectedScope,
            expectedRevision: expectedRevision,
            expectedTurnID: expectedTurnID
        )
    }
}
