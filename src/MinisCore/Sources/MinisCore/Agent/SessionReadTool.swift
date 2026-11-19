import Foundation

/// Read-only access to persisted chat sessions for the macOS Agent.
///
/// The tool deliberately exposes a small, sanitized projection instead of
/// returning the session JSON file. This keeps credentials and persistence
/// details out of the model context while still allowing an explicitly
/// authorized user request to inspect another conversation.
public enum SessionReadTool {
    public static let toolName = "session_read"

    private static let defaultLimit = 20
    private static let maxLimit = 50
    private static let defaultMaxChars = 8_000
    private static let minMaxChars = 200
    private static let maxMaxChars = 8_000

    /// Legacy entry point retained only to keep the old executor composition
    /// source-compatible. It is intentionally fail-closed: a model/tool call
    /// cannot create an authorization capability from `[String: Any]` input.
    public static func read(input: [String: Any], manager: SessionManager) throws -> String {
        throw CrossSessionReadAuthorizationError.capabilityRequired
    }

    /// Execute a read-only session query with an explicit in-memory capability.
    ///
    /// Authorization is checked before loading the target session. The model
    /// input may contain arbitrary strings, but none of them can replace the
    /// typed capability supplied by the composition root.
    public static func read(
        input: [String: Any],
        manager: SessionManager,
        authorization: CrossSessionReadAuthorization,
        context: SessionReadExecutionContext,
        now: Date = Date(),
        knownSecretsProvider: @Sendable () -> [String] = { [] }
    ) throws -> String {
        guard let scope = input["scope"] as? String,
              let readScope = SessionReadScope(rawValue: scope) else {
            throw ToolExecutorError.invalidParameter("scope")
        }
        // list/export need live App state (trash, sidebar export); the App
        // composition root serves them through `authorizeSessionLevel`.
        guard !readScope.isSessionLevel else {
            throw ToolExecutorError.toolNotConfigured("session_read.\(scope)")
        }
        guard let sessionID = input["session_id"] as? String,
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolExecutorError.missingParameter("session_id")
        }
        // Reject path-like identifiers before consulting the capability. A
        // malformed target must not become an authorization oracle.
        guard isSafeSessionID(sessionID) else {
            throw ToolExecutorError.invalidParameter("session_id")
        }
        do {
            try authorization.validate(
                targetSessionID: sessionID,
                scope: readScope,
                context: context,
                now: now
            )
        } catch let error as CrossSessionReadAuthorizationError {
            // A stopped, ended-turn, or cross-restart decision is terminal at
            // this consumer. Do not let a late approval retry it with a
            // repaired context; preserve the first error for this call.
            switch error {
            case .stopped:
                authorization.invalidate(reason: .stopped)
            case .turnMismatch:
                authorization.invalidate(reason: .turnEnded)
            case .restartRevisionMismatch:
                authorization.invalidate(reason: .revoked)
            default:
                break
            }
            throw error
        }
        // Consume immediately after validation and before touching persisted
        // session data. Concurrent or late tool calls cannot reuse the same
        // capability, including when the target lookup later fails.
        guard authorization.consume(targetSessionID: sessionID, scope: readScope) else {
            throw CrossSessionReadAuthorizationError.replayed
        }
        // Snapshot trusted in-memory values once, only after authorization is
        // consumed. Model input cannot provide or override this source.
        let knownSecrets = knownSecretsProvider()
        guard let session = manager.loadSessionIncludingArchived(id: sessionID) else {
            throw ToolExecutorError.fileNotFound(sessionID)
        }

        switch readScope {
        case .list, .export:
            throw ToolExecutorError.invalidParameter("scope")
        case .metadata:
            return try encode(metadataEnvelope(for: session, knownSecrets: knownSecrets))
        case .messages:
            let offset = max(0, intValue(input["offset"]) ?? 0)
            let limit = min(maxLimit, max(1, intValue(input["limit"]) ?? defaultLimit))
            let maxChars = min(maxMaxChars, max(minMaxChars, intValue(input["max_chars"]) ?? defaultMaxChars))
            let revision = "\(context.restartRevision):\(session.transcriptRevision)"
            if let requestedRevision = input["revision"] as? String, requestedRevision != revision {
                throw SessionReadBoundedTextProjectionError.cursorRevisionMismatch
            }
            if let requestedTurnID = intValue(input["turn_id"]), requestedTurnID != context.turnID {
                throw SessionReadBoundedTextProjectionError.cursorTurnMismatch
            }
            return try encode(messagesEnvelope(
                for: session,
                offset: offset,
                limit: limit,
                maxChars: maxChars,
                revision: revision,
                turnID: context.turnID,
                knownSecrets: knownSecrets
            ))
        }
    }

    /// One row of the `scope=list` projection: metadata only, never message text.
    public struct SessionListRow: Sendable {
        public enum State: String, Sendable { case active, archived, trashed }
        public let sessionID: String
        public let title: String
        public let updatedAt: Date
        public let state: State
        public let current: Bool
        public let pinned: Bool
        public let unread: Bool
        public let projectName: String?
        public let group: String?

        public init(sessionID: String, title: String, updatedAt: Date, state: State, current: Bool,
                    pinned: Bool, unread: Bool, projectName: String?, group: String?) {
            self.sessionID = sessionID
            self.title = title
            self.updatedAt = updatedAt
            self.state = state
            self.current = current
            self.pinned = pinned
            self.unread = unread
            self.projectName = projectName
            self.group = group
        }
    }

    /// Validate and consume the capability for a `list`/`export` call (target = the
    /// current session). Returns nil for the per-session scopes, which `read` serves.
    public static func authorizeSessionLevel(
        input: [String: Any],
        authorization: CrossSessionReadAuthorization,
        context: SessionReadExecutionContext,
        now: Date
    ) throws -> SessionReadScope? {
        guard let scope = input["scope"] as? String,
              let readScope = SessionReadScope(rawValue: scope) else {
            throw ToolExecutorError.invalidParameter("scope")
        }
        guard readScope.isSessionLevel else { return nil }
        try authorization.validate(
            targetSessionID: context.currentConversationID, scope: readScope, context: context, now: now
        )
        guard authorization.consume(targetSessionID: context.currentConversationID, scope: readScope) else {
            throw CrossSessionReadAuthorizationError.replayed
        }
        return readScope
    }

    /// JSON for `scope=list`. `query` matches title/project/group metadata only.
    public static func listEnvelope(
        rows: [SessionListRow], query: String?, knownSecrets: [String]
    ) throws -> String {
        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let matching = rows.filter { row in
            needle.isEmpty || [row.title, row.projectName, row.group].contains {
                $0?.localizedCaseInsensitiveContains(needle) == true
            }
        }
        let sessions: [[String: Any]] = matching.map { row in
            var item: [String: Any] = [
                "session_id": row.sessionID,
                "title": ContentSecretRedactor.redact(row.title, knownSecrets: knownSecrets),
                "updated_at": iso8601(row.updatedAt),
                "state": row.state.rawValue,
                "current": row.current,
                "pinned": row.pinned,
                "unread": row.unread,
            ]
            if let name = row.projectName {
                item["project_name"] = ContentSecretRedactor.redact(name, knownSecrets: knownSecrets)
            }
            if let group = row.group {
                item["group"] = ContentSecretRedactor.redact(group, knownSecrets: knownSecrets)
            }
            return item
        }
        return try encode(["sessions": sessions])
    }

    /// Convenience overload for composition roots that keep the runtime turn
    /// fields separately instead of constructing `SessionReadExecutionContext`.
    public static func read(
        input: [String: Any],
        manager: SessionManager,
        authorization: CrossSessionReadAuthorization,
        currentConversationID: String,
        turnID: Int,
        isStopped: Bool = false,
        sourceSessionID: String? = nil,
        restartRevision: String = "initial",
        now: Date = Date(),
        knownSecretsProvider: @Sendable () -> [String] = { [] }
    ) throws -> String {
        try read(
            input: input,
            manager: manager,
            authorization: authorization,
            context: SessionReadExecutionContext(
                currentConversationID: currentConversationID,
                turnID: turnID,
                isStopped: isStopped,
                sourceSessionID: sourceSessionID,
                restartRevision: restartRevision
            ),
            now: now,
            knownSecretsProvider: knownSecretsProvider
        )
    }

    private static func metadataEnvelope(for session: ChatSession, knownSecrets: [String]) -> [String: Any] {
        let hasSessionOverride = session.modelID != nil || session.providerTypeRaw != nil
        var metadata: [String: Any] = [
            "session_id": session.id,
            "title": ContentSecretRedactor.redact(session.title, knownSecrets: knownSecrets),
            "created_at": iso8601(session.createdAt),
            "updated_at": iso8601(session.updatedAt),
            "message_count": session.messages.count,
            "model_id": session.modelID.map { ContentSecretRedactor.redact($0, knownSecrets: knownSecrets) as Any } ?? NSNull(),
            "provider": session.providerTypeRaw.map { ContentSecretRedactor.redact($0, knownSecrets: knownSecrets) as Any } ?? NSNull(),
            "model_source": hasSessionOverride ? "session_override" : "global_default_unresolved",
        ]
        if !hasSessionOverride {
            metadata["model_note"] = "该会话没有保存会话级模型覆盖，无法从历史记录推断当时的全局默认模型。"
        }
        return [
            "ok": true,
            "tool": toolName,
            "scope": "metadata",
            "metadata": metadata,
        ]
    }

    private static func messagesEnvelope(
        for session: ChatSession,
        offset: Int,
        limit: Int,
        maxChars: Int,
        revision: String,
        turnID: Int,
        knownSecrets: [String]
    ) throws -> [String: Any] {
        let visible = session.messages.filter { message in
            message.role == .user || message.role == .assistant
        }
        let pageStart = min(offset, visible.count)
        // Redact the complete values before the bounded projection. The
        // projection then owns all character/byte accounting and never sees a
        // secret-bearing pre-redaction string.
        let redactedMessages = visible.map { message in
            ContentSecretRedactor.redact(message.content, knownSecrets: knownSecrets)
        }
        // Keep D-SESSIONREAD-04's clamped out-of-range behavior while binding
        // the actual projection cursor to the immutable snapshot identity.
        let projection = try SessionReadPageProjection.project(
            messages: redactedMessages,
            sessionID: session.id,
            scope: .messages,
            revision: revision,
            turnID: turnID,
            offset: pageStart,
            limit: limit,
            maxCharacters: maxChars,
            maxBytes: SessionReadBoundedTextProjection.maximumBytes
        )
        let pageMessages = visible.dropFirst(pageStart).prefix(projection.messages.count)
        let page = zip(pageMessages, projection.messages).map { message, projected in
            var item: [String: Any] = [
                "role": message.role.rawValue,
                "text": projected.text,
                "created_at": NSNull(),
                "character_count": projected.characterCount,
                "byte_count": projected.byteCount,
                "source_character_count": projected.sourceCharacterCount,
                "source_byte_count": projected.sourceByteCount,
                "max_characters": projected.maxCharacters,
                "max_bytes": projected.maxBytes,
            ]
            if projected.isTruncated {
                item["truncated"] = true
            }
            return item
        }
        var nextOffset: Any = NSNull()
        if let projectionNextOffset = projection.nextOffset {
            nextOffset = projectionNextOffset
        }
        return [
            "ok": true,
            "tool": toolName,
            "scope": "messages",
            "session_id": session.id,
            // Preserve the requested offset for existing consumers; cursor_offset
            // records the clamped offset used to derive continuation.
            "offset": offset,
            "cursor_offset": projection.offset,
            "limit": limit,
            "max_chars": maxChars,
            "max_bytes": SessionReadBoundedTextProjection.maximumBytes,
            "revision": revision,
            "turn_id": turnID,
            "total": projection.total,
            "messages": page,
            "has_more": projection.hasMore,
            "next_offset": nextOffset,
        ]
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        return nil
    }

    private static func isSafeSessionID(_ id: String) -> Bool {
        guard id != ".", id != "..", !id.hasPrefix(".") else { return false }
        return id.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\")) == nil
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
