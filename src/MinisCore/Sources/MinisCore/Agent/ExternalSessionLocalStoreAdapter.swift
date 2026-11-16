import Foundation

// MARK: - Existing-session adapter: local-store read-side implementation
//
// Concrete read-side implementation of the `ExistingAgentSessionAdapter` seam for the
// machine-local session storage that already exists in this app: the canonical
// `SessionStore` (one JSON file per session at `<root>/sessions/<id>.json`, see
// Session/SessionStore.swift:204-378). It maps stored `ChatSession` records onto the
// versioned contract values `ExternalSessionThreadPageV1 / ExternalSessionReadPageV1 /
// ExternalSessionStatusV1`.
//
// This file implements ONLY the read side (`source`, `listThreads`, `read`, `status`).
// The read/control capability split is a Canonical contract requirement, quoted verbatim
// from `ExternalSessionContract.swift:663-664`:
//
//     /// Existing-session adapter seam only. Implementations and production registration
//     /// belong to later stages and must enforce the read/control capability split before
//     /// transport I/O.
//
// Accordingly `control(controlGrant:)` below performs no session operation and asserts no
// control semantics of its own: it is a terminal `unsupported` receipt. The control side
// is a separately-owned capability lane and must not be co-implemented here.
//
// Authorization is delegated to the existing composition-root authority: every call
// requires an `ExternalSessionReadGrantV1` and is checked fail-closed against
// `ExternalSessionAuthorizationLedgerV1.isAuthorizationActive` (never-issued pairs and
// epoch mismatches both fail, including a re-check after any await, per the ledger's
// documented enforcement at ExternalSessionAuthorizationLedger.swift:14-16). No new
// authorization semantics are invented here, and the source/profile/lifetime/target/
// scope rules mirror the existing app-facing gate (`ExternalSessionAppAdapter.
// validateReadGrant`) value-for-value.
//
// Payloads crossing this boundary stay redacted and bounded: message content is passed
// through `ContentSecretRedactor` and `SessionReadBoundedTextProjection` before entering
// an `ExternalSessionRedactedPayloadV1` summary, and `sourceRef` only ever carries the
// store-relative path pattern `sessions/<id>.json#message:<index>`, never an absolute
// filesystem path.

/// Local-store read-side adapter: maps `SessionStore` sessions to the
/// `ExternalSessionContractV1` read surfaces.
public struct ExternalSessionLocalStoreAdapter: ExistingAgentSessionAdapter {
    public enum Failure: Error, Equatable, Sendable {
        /// The request or status target names a different external session source.
        case requestedSourceMismatch(ExternalSessionSourceID)
        /// The grant was minted for a different external session source.
        case grantSourceMismatch(ExternalSessionSourceID)
        /// The grant was minted for a different profile.
        case grantProfileMismatch(ExternalSessionProfileID)
        case grantNotYetValid
        case grantExpired
        /// The pair was never issued through the ledger, or its revocation epoch no
        /// longer matches (fail-closed for both, per the ledger's activity contract).
        case grantNotAuthorized(revocationEpoch: UInt64)
        case scopeNotGranted(ExternalSessionReadScopeV1)
        case targetMismatch
        case invalidLimit(UInt16)
        case invalidCursor(String)
        case unknownThread(ExternalSessionThreadID)
    }

    /// Bounded-text budget applied to every payload summary produced here.
    static let summaryMaxCharacters = 512
    static let summaryMaxBytes = 2_048

    public let source: ExternalSessionSourceV1
    /// The local session store being projected. This adapter only reads from it.
    private let store: SessionStore
    /// The composition-root authorization ledger; the single activity authority.
    private let authorizationLedger: ExternalSessionAuthorizationLedgerV1
    private let clock: @Sendable () -> Date

    private let sourceID: ExternalSessionSourceID
    private let profileID: ExternalSessionProfileID

    public init(
        sourceID: ExternalSessionSourceID,
        profileID: ExternalSessionProfileID,
        hostID: String,
        adapterVersion: String = "local-store-adapter/1",
        store: SessionStore,
        authorizationLedger: ExternalSessionAuthorizationLedgerV1,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sourceID = sourceID
        self.profileID = profileID
        self.store = store
        self.authorizationLedger = authorizationLedger
        self.clock = clock
        // The declared capability set is exactly the read side implemented here. No
        // control capability (resume/fork/steer/interrupt/approval) is ever advertised
        // by this adapter, keeping the Canonical read/control split structural.
        self.source = ExternalSessionSourceV1(
            sourceID: sourceID,
            kind: .other,
            adapterVersion: adapterVersion,
            profileID: profileID,
            hostID: hostID,
            capabilities: [.readMetadata, .readMessages, .status],
            authState: .authorized
        )
    }

    // MARK: - listThreads

    public func listThreads(
        query: ExternalSessionThreadQueryV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionThreadPageV1 {
        try validateReadGrantFields(
            readGrant,
            requestedTarget: .source(query.sourceID),
            requiredScope: .metadata,
            projectID: query.projectID
        )
        guard query.sourceID == sourceID else {
            throw Failure.requestedSourceMismatch(query.sourceID)
        }
        guard query.limit > 0 else { throw Failure.invalidLimit(query.limit) }
        let offset = try Self.offset(from: query.cursor, prefix: "local:offset:")
        try await requireAuthorizationActive(readGrant)

        let visible = deterministicOrder(store.listSessions())
            .filter { session in
                guard let projectID = query.projectID else { return true }
                return session.projectID == projectID.rawValue
            }
        guard offset <= visible.count else { throw Failure.invalidCursor(query.cursor.rawValue) }
        let end = min(offset + Int(query.limit), visible.count)

        let threads = visible[offset..<end].map { session in
            ExternalSessionThreadV1(
                sourceID: sourceID,
                threadID: ExternalSessionThreadID(rawValue: session.id),
                projectID: session.projectID.map(ExternalSessionProjectID.init(rawValue:)),
                title: session.title,
                status: Self.threadStatus(of: session),
                updatedAt: session.updatedAt,
                sourceCursor: ExternalSessionCursorV1(
                    rawValue: "local:rev:\(session.transcriptRevision)"
                ),
                readable: true
            )
        }
        return ExternalSessionThreadPageV1(
            sourceID: sourceID,
            threads: threads,
            nextCursor: end < visible.count
                ? ExternalSessionCursorV1(rawValue: "local:offset:\(end)")
                : nil,
            observedCursor: ExternalSessionCursorV1(rawValue: "local:size:\(visible.count)")
        )
    }

    // MARK: - read

    public func read(
        request: ExternalSessionReadRequestV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionReadPageV1 {
        try validateReadGrantFields(
            readGrant,
            requestedTarget: .thread(request.threadID),
            requiredScope: .messages
        )
        // A thread-scoped grant says nothing about the query's source identity; the
        // app-facing gate checks this same equality (ExternalSessionAppAdapter.swift:879).
        guard request.sourceID == sourceID else {
            throw Failure.requestedSourceMismatch(request.sourceID)
        }
        guard request.limit > 0 else { throw Failure.invalidLimit(request.limit) }
        let windowStart = try Self.offset(from: request.cursor, prefix: "local:msg:")
        try await requireAuthorizationActive(readGrant)

        guard let session = store.loadSession(id: request.threadID.rawValue) else {
            throw Failure.unknownThread(request.threadID)
        }
        let messages = session.messages
        guard windowStart <= messages.count else {
            throw Failure.invalidCursor(request.cursor.rawValue)
        }
        let windowEnd = min(windowStart + Int(request.limit), messages.count)

        let turns = turns(of: session, windowStart: windowStart, windowEnd: windowEnd)
            .filter { turn in
                guard let requested = request.turnID else { return true }
                return turn.turnID == requested
            }
        let events = (windowStart..<windowEnd).map { index in
            event(of: session, messageIndex: index)
        }
        // Re-check after the awaits above: a revocation that landed while this call was
        // suspended must drop the page instead of delivering it.
        try await requireAuthorizationActive(readGrant)

        return ExternalSessionReadPageV1(
            sourceID: sourceID,
            threadID: request.threadID,
            turns: turns,
            events: events,
            nextCursor: windowEnd < messages.count
                ? ExternalSessionCursorV1(rawValue: "local:msg:\(windowEnd)")
                : nil,
            observedCursor: ExternalSessionCursorV1(
                rawValue: "local:rev:\(session.transcriptRevision)"
            )
        )
    }

    // MARK: - status

    public func status(
        target: ExternalSessionStatusTargetV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionStatusV1 {
        let requestedTarget = target.threadID.map(ExternalSessionReadTargetV1.thread)
            ?? .source(target.sourceID)
        try validateReadGrantFields(
            readGrant,
            requestedTarget: requestedTarget,
            requiredScope: .status
        )
        guard target.sourceID == sourceID else {
            throw Failure.requestedSourceMismatch(target.sourceID)
        }
        try await requireAuthorizationActive(readGrant)

        guard let threadID = target.threadID else {
            // Source-level status: report only the bounded store observation.
            let sessionCount = deterministicOrder(store.listSessions()).count
            return ExternalSessionStatusV1(
                sourceID: sourceID,
                threadID: nil,
                turnID: nil,
                threadStatus: nil,
                turnStatus: nil,
                observedCursor: ExternalSessionCursorV1(rawValue: "local:size:\(sessionCount)"),
                latestSequence: nil
            )
        }
        guard let session = store.loadSession(id: threadID.rawValue) else {
            throw Failure.unknownThread(threadID)
        }
        let turns = turns(of: session, windowStart: 0, windowEnd: session.messages.count)
        let turnStatus: ExternalSessionTurnStatusV1?
        if let requested = target.turnID {
            guard let match = turns.first(where: { $0.turnID == requested }) else {
                throw Failure.unknownThread(threadID)
            }
            turnStatus = match.status
        } else {
            turnStatus = turns.last?.status
        }
        // Post-await re-check before delivery (same rule as `read`).
        try await requireAuthorizationActive(readGrant)
        return ExternalSessionStatusV1(
            sourceID: sourceID,
            threadID: threadID,
            turnID: target.turnID,
            threadStatus: Self.threadStatus(of: session),
            turnStatus: turnStatus,
            observedCursor: ExternalSessionCursorV1(
                rawValue: "local:rev:\(session.transcriptRevision)"
            ),
            latestSequence: UInt64(session.messages.count)
        )
    }

    // MARK: - control (deliberately NOT implemented in this lane)

    /// The control side is a separate capability lane. Per the Canonical read/control
    /// capability split quoted at the top of this file
    /// (`ExternalSessionContract.swift:663-664`: implementations "must enforce the
    /// read/control capability split before transport I/O"), this adapter performs no
    /// control operation and asserts no control semantics; the terminal outcome is
    /// `unsupported` with no side effect on any session.
    public func control(
        request: ExternalSessionControlRequestV1,
        controlGrant: ExternalSessionControlGrantV1
    ) async throws -> ExternalSessionControlReceiptV1 {
        ExternalSessionControlReceiptV1(
            sourceID: request.sourceID,
            threadID: request.threadID,
            turnID: request.turnID,
            operation: request.operation,
            outcome: .unsupported,
            operationID: nil,
            sourceCursor: .beginning,
            detail: "control capability is a separate lane; read-only local-store adapter"
        )
    }

    // MARK: - Grant validation (fail-closed; mirrors the app-facing gate rules)

    private func validateReadGrantFields(
        _ grant: ExternalSessionReadGrantV1,
        requestedTarget: ExternalSessionReadTargetV1,
        requiredScope: ExternalSessionReadScopeV1,
        projectID: ExternalSessionProjectID? = nil
    ) throws {
        guard grant.sourceID == sourceID else {
            throw Failure.grantSourceMismatch(grant.sourceID)
        }
        guard grant.profileID == profileID else {
            throw Failure.grantProfileMismatch(grant.profileID)
        }
        let now = clock()
        guard grant.issuedAt <= now else { throw Failure.grantNotYetValid }
        guard now < grant.expiresAt else { throw Failure.grantExpired }
        guard grant.scopes.contains(requiredScope) else {
            throw Failure.scopeNotGranted(requiredScope)
        }
        guard Self.targetMatches(
            grant.target,
            requestedTarget: requestedTarget,
            projectID: projectID,
            sourceID: sourceID
        ) else {
            throw Failure.targetMismatch
        }
    }

    private func requireAuthorizationActive(
        _ grant: ExternalSessionReadGrantV1
    ) async throws {
        guard await authorizationLedger.isAuthorizationActive(
            sourceID: grant.sourceID,
            profileID: grant.profileID,
            revocationEpoch: grant.revocationEpoch
        ) else {
            throw Failure.grantNotAuthorized(revocationEpoch: grant.revocationEpoch)
        }
    }

    /// Target-match table mirroring `ExternalSessionAppAdapter.targetMatches`
    /// (src/MinisCanvasApp/Sources/MinisCanvasApp/ExternalSessionAppAdapter.swift:1086-1103)
    /// so both gates agree rule-for-rule; no new authorization semantics are added.
    static func targetMatches(
        _ grantedTarget: ExternalSessionReadTargetV1,
        requestedTarget: ExternalSessionReadTargetV1,
        projectID: ExternalSessionProjectID?,
        sourceID: ExternalSessionSourceID
    ) -> Bool {
        switch (grantedTarget, requestedTarget) {
        case let (.source(granted), .source(requested)):
            return granted == requested && granted == sourceID
        case let (.source(granted), .thread):
            return granted == sourceID
        case let (.project(granted), .source(requested)):
            return projectID != nil && granted == projectID && requested == sourceID
        case let (.thread(granted), .thread(requested)):
            return granted == requested
        default:
            return false
        }
    }

    // MARK: - Cursors and ordering

    private func deterministicOrder(_ sessions: [ChatSession]) -> [ChatSession] {
        sessions.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    /// Adapter-owned opaque cursors. The domain persists and compares them opaquely;
    /// only this adapter decodes its own `local:*` offsets (ExternalSessionContract.swift:81-91).
    static func offset(
        from cursor: ExternalSessionCursorV1,
        prefix: String
    ) throws -> Int {
        if cursor == .beginning { return 0 }
        guard cursor.rawValue.hasPrefix(prefix),
              let value = Int(cursor.rawValue.dropFirst(prefix.count)),
              value >= 0 else {
            throw Failure.invalidCursor(cursor.rawValue)
        }
        return value
    }

    // MARK: - Transcript mapping (turns / events / status)

    /// Turns are user-message-anchored runs: a turn starts at each `.user` message and
    /// owns the following non-user messages; leading non-user messages form a turn
    /// anchored at index 0. Only turns overlapping `[windowStart, windowEnd)` are
    /// returned. Statuses are factual observations of the persisted transcript: a turn
    /// ending on an assistant message is `succeeded`, one ending on a bare user message
    /// is `waitingInput`, one ending on a tool message is `running`, an empty
    /// transcript window yields `unknown`.
    func turns(
        of session: ChatSession,
        windowStart: Int,
        windowEnd: Int
    ) -> [ExternalSessionTurnV1] {
        var starts: [Int] = session.messages.indices.filter {
            session.messages[$0].role == .user
        }
        if let first = session.messages.indices.first,
           session.messages[first].role != .user {
            starts.insert(first, at: 0)
        }
        var result: [ExternalSessionTurnV1] = []
        for (position, start) in starts.enumerated() {
            let end = position + 1 < starts.count
                ? starts[position + 1]
                : session.messages.count
            guard end > windowStart, start < windowEnd else { continue }
            let lastRole = session.messages[start..<end].last?.role
            result.append(ExternalSessionTurnV1(
                sourceID: sourceID,
                threadID: ExternalSessionThreadID(rawValue: session.id),
                turnID: ExternalSessionTurnID(rawValue: "local-turn-\(start)"),
                status: Self.turnStatus(lastRole: lastRole),
                providerID: session.providerTypeRaw,
                modelID: session.modelID,
                sourceCursor: ExternalSessionCursorV1(rawValue: "local:msg:\(end)")
            ))
        }
        return result
    }

    static func turnStatus(lastRole: LLMMessage.Role?) -> ExternalSessionTurnStatusV1 {
        switch lastRole {
        case .assistant?: return .succeeded
        case .user?: return .waitingInput
        case .tool?: return .running
        case nil: return .unknown
        }
    }

    static func threadStatus(of session: ChatSession) -> ExternalSessionThreadStatusV1 {
        switch session.messages.last?.role {
        case .assistant?: return .completed
        case .user?: return .waiting
        case .tool?: return .unknown
        case nil: return .discovered
        }
    }

    func event(
        of session: ChatSession,
        messageIndex: Int
    ) -> ExternalSessionEventV1 {
        let message = session.messages[messageIndex]
        let anchoredTurn = turns(of: session, windowStart: messageIndex, windowEnd: messageIndex + 1).first
        return ExternalSessionEventV1(
            eventID: ExternalSessionEventID(rawValue: "local-event-\(session.id)-\(messageIndex)"),
            sourceID: sourceID,
            threadID: ExternalSessionThreadID(rawValue: session.id),
            turnID: anchoredTurn?.turnID,
            sequence: UInt64(messageIndex) + 1,
            sourceCursor: ExternalSessionCursorV1(rawValue: "local:msg:\(messageIndex + 1)"),
            occurredAt: session.updatedAt,
            required: true,
            kind: .progress,
            payload: Self.redactedPayload(of: message),
            sourceRef: "local-store:sessions/\(session.id).json#message:\(messageIndex)"
        )
    }

    /// Redacted + bounded payload summary. Secret-bearing substrings are masked by the
    /// app-wide `ContentSecretRedactor`, then the summary is truncated with the
    /// existing Unicode-safe `SessionReadBoundedTextProjection` budget.
    static func redactedPayload(of message: LLMMessage) -> ExternalSessionRedactedPayloadV1 {
        let redacted = ContentSecretRedactor.redact(message.content)
        guard let bounded = try? SessionReadBoundedTextProjection(
            text: redacted,
            maxCharacters: summaryMaxCharacters,
            maxBytes: summaryMaxBytes
        ) else {
            // The budgets above are fixed in-range constants, so failure is not
            // expected; degrade to an empty summary rather than leaking text.
            return ExternalSessionRedactedPayloadV1(kind: message.role.rawValue, summary: "")
        }
        var summary = bounded.text
        if bounded.isTruncated { summary += "…" }
        return ExternalSessionRedactedPayloadV1(kind: message.role.rawValue, summary: summary)
    }
}
