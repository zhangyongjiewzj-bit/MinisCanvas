import MinisCore

/// Loads canonical tool-event summaries in bounded pages, newest first for
/// paging while preserving chronological order in the visible inspector.
/// Event summaries are already bounded by ConversationEventProjection; this
/// layer never requests or transports raw tool output.
struct ChatInspectorToolEventPage: Equatable, Sendable {
    let events: [MinisCore.ConversationEvent]
    let omittedCount: Int
    let visiblePageCount: Int
    let totalPages: Int
}

enum ChatInspectorToolEventPagination {
    static func project(
        events: [MinisCore.ConversationEvent], requestedPageCount: Int, pageSize: Int
    ) -> ChatInspectorToolEventPage {
        guard pageSize > 0 else {
            return ChatInspectorToolEventPage(
                events: [], omittedCount: events.count,
                visiblePageCount: 0, totalPages: 0
            )
        }
        let totalPages = max(1, AgentOutputPageMath.ceilDiv(events.count, pageSize))
        let visiblePageCount = min(max(1, requestedPageCount), totalPages)
        let cursor = AgentOutputPageCursor(
            pageIndex: visiblePageCount - 1, pageSize: pageSize
        )
        guard case .window(_, let firstLine, let lineCount, _) =
                AgentOutputPaginator.paginate(cursor: cursor, bodyLineCount: events.count)
        else {
            return ChatInspectorToolEventPage(
                events: [], omittedCount: events.count,
                visiblePageCount: 0, totalPages: totalPages
            )
        }
        let visibleCount = firstLine + lineCount
        return ChatInspectorToolEventPage(
            events: Array(events.suffix(visibleCount)),
            omittedCount: events.count - visibleCount,
            visiblePageCount: visiblePageCount,
            totalPages: totalPages
        )
    }

    static func nextPageCount(
        events: [MinisCore.ConversationEvent], currentPageCount: Int, pageSize: Int
    ) -> Int {
        let current = project(
            events: events, requestedPageCount: currentPageCount, pageSize: pageSize
        )
        guard current.visiblePageCount < current.totalPages else {
            return current.visiblePageCount
        }
        return current.visiblePageCount + 1
    }
}

/// View-local cursor state. The key is the canonical viewer session, so A's
/// extra pages cannot appear in B after a session switch.
struct ChatInspectorToolEventPageState {
    private var pageCountsBySession: [String: Int] = [:]

    func page(
        sessionID: String?, events: [MinisCore.ConversationEvent], pageSize: Int
    ) -> ChatInspectorToolEventPage {
        let requested = sessionID.flatMap { pageCountsBySession[$0] } ?? 1
        return ChatInspectorToolEventPagination.project(
            events: events, requestedPageCount: requested, pageSize: pageSize
        )
    }

    /// Bind a page request to the snapshot that rendered its button. Reject
    /// stale A callbacks after the visible ChatStore session has become B.
    @discardableResult
    mutating func loadOlderIfCurrent(
        viewerSessionID: String?,
        activeSessionID: String?,
        canonicalEvents: [MinisCore.ConversationEvent],
        pageSize: Int
    ) -> Bool {
        guard let viewerSessionID, !viewerSessionID.isEmpty,
              activeSessionID == viewerSessionID else { return false }
        let events = canonicalEvents.filter {
            $0.identity.sessionID == viewerSessionID && $0.kind == .tool
        }
        loadOlder(sessionID: viewerSessionID, events: events, pageSize: pageSize)
        return true
    }

    mutating func loadOlder(
        sessionID: String, events: [MinisCore.ConversationEvent], pageSize: Int
    ) {
        guard !sessionID.isEmpty else { return }
        pageCountsBySession[sessionID] = ChatInspectorToolEventPagination.nextPageCount(
            events: events,
            currentPageCount: pageCountsBySession[sessionID] ?? 1,
            pageSize: pageSize
        )
    }
}
