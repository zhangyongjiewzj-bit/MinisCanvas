import Foundation
import MinisCore

/// UI values are frozen by the original turn. Projection and the canonical
/// Store read run together off MainActor; neither operation grants authority.
struct AutomaticCompactionSourcePreprocessor: Sendable {
    enum Stage: Sendable { case projection, canonicalRead }
    struct Input: Sendable {
        let sourceID: String
        let assistantMessageID: UUID
        let initialHistory: [ChatMessageUI]?
        let currentHistory: [ChatMessageUI]
        let localSession: ChatThread
        let uiRevision: UInt64?
    }
    struct AdoptionInput: Sendable {
        let source: AgentLoopChatEngine.AutomaticCompactionSource
        let checkpoint: CompactionCheckpoint
        let currentMessages: [ChatMessageUI]
        let assistantMessageID: UUID
    }

    struct CanonicalProjection: Sendable {
        let histories: [[LLMMessage]]
        let canonical: MinisCore.ChatSession?
    }

    let observeWork: (@Sendable (Stage) -> Void)?
    let pauseBeforeRead: (@Sendable () async throws -> Void)?

    init(observeWork: (@Sendable (Stage) -> Void)? = nil,
         pauseBeforeRead: (@Sendable () async throws -> Void)? = nil) {
        self.observeWork = observeWork
        self.pauseBeforeRead = pauseBeforeRead
    }

    static func lineage(of local: ChatThread) -> SessionLineageIdentity {
        .init(lineageVersion: local.lineageVersion, rootSessionID: local.rootSessionID,
            parentSessionID: local.parentSessionID, forkedFromSessionID: local.forkedFromSessionID,
            forkedThroughTranscriptRevision: local.forkedThroughTranscriptRevision,
            forkedThroughMessageID: local.forkedThroughMessageID)
    }

    /// Only frozen histories and the original Store owner cross this boundary.
    /// Authorization and the synchronous write transaction remain at the caller.
    nonisolated(nonsending) func prepareCanonicalProjection(
        histories: [[ChatMessageUI]], sessionID: String, store: SessionStore?
    ) async throws -> CanonicalProjection {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            if let pauseBeforeRead { try await pauseBeforeRead() }
            try Task.checkCancellation()
            observeWork?(.projection)
            let projected = try histories.map { try ChatHistoryPreprocessor.project($0) }
            try Task.checkCancellation()
            let canonical: MinisCore.ChatSession?
            if let store {
                observeWork?(.canonicalRead)
                canonical = store.loadSession(id: sessionID)
            } else { canonical = nil }
            try Task.checkCancellation()
            return CanonicalProjection(histories: projected, canonical: canonical)
        }
        let result = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        return result
    }

    /// This point-read belongs to a completed durable commit or its error
    /// classification. Preserve the original synchronous finalization: parent
    /// cancellation does not invent a new refusal after the commit occurred.
    nonisolated(nonsending) func readCanonicalForFinalization(
        sessionID: String, store: SessionStore,
        pauseBeforeRead: (@Sendable () async -> Void)? = nil
    ) async -> MinisCore.ChatSession? {
        let worker = Task.detached(priority: .userInitiated) {
            if let pauseBeforeRead { await pauseBeforeRead() }
            observeWork?(.canonicalRead)
            return store.loadSession(id: sessionID)
        }
        return await worker.value
    }

    nonisolated(nonsending) func readCanonicalSessions(
        sessionID: String, stores: [SessionStore]
    ) async throws -> [MinisCore.ChatSession?] {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            if let pauseBeforeRead { try await pauseBeforeRead() }
            return try stores.map { store in
                try Task.checkCancellation()
                observeWork?(.canonicalRead)
                return store.loadSession(id: sessionID)
            }
        }
        let sessions = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        return sessions
    }

    nonisolated(nonsending) func prepareAdoption(_ input: AdoptionInput, store: SessionStore)
        async throws -> MinisCore.ChatSession? {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) { () throws -> MinisCore.ChatSession? in
            try Task.checkCancellation()
            if let pauseBeforeRead { try await pauseBeforeRead() }
            try Task.checkCancellation()
            observeWork?(.canonicalRead)
            guard let canonical = store.loadSession(id: input.source.session.id),
                  canonical.transcriptRevision == input.checkpoint.resultTranscriptRevision,
                  canonical.lineageIdentity == input.source.session.lineageIdentity,
                  canonical.messages == input.source.session.messages else { return nil }
            try Task.checkCancellation()
            observeWork?(.canonicalRead)
            guard (try? store.loadLatestCompactionCheckpoint(sessionID: input.source.session.id))
                    == input.checkpoint else { return nil }
            observeWork?(.projection)
            let current = input.currentMessages.filter { $0.role != .system }
            guard current.count == input.source.closedPrefixCount + 1,
                  current.last?.id == input.assistantMessageID,
                  current.last?.isStreaming == true,
                  try ChatHistoryPreprocessor.project(Array(current.dropLast()))
                    == Array(input.source.session.messages.prefix(input.source.closedPrefixCount)) else { return nil }
            try Task.checkCancellation()
            return canonical
        }
        let canonical = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        return canonical
    }

    nonisolated(nonsending) func prepare(_ input: Input, store: SessionStore) async throws
        -> AgentLoopChatEngine.AutomaticCompactionSource? {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) { () throws -> AgentLoopChatEngine.AutomaticCompactionSource? in
            try Task.checkCancellation()
            observeWork?(.projection)
            guard let initial = input.initialHistory else {
                return nil
            }
            let initialUI = initial.filter { $0.role != .system }
            let current = input.currentHistory.filter { $0.role != .system }
            let closedUI = try ChatHistoryPreprocessor.project(Array(initialUI.dropLast()))
            let currentProjection = try ChatHistoryPreprocessor.project(current)
            guard current.last?.id == input.assistantMessageID,
                  current.last?.isStreaming == true, !closedUI.isEmpty,
                  Array(currentProjection.dropLast()) == closedUI else {
                return nil
            }
            let initialPlaceholder = initialUI.last?.asLLMMessage()
            if let pauseBeforeRead { try await pauseBeforeRead() }
            try Task.checkCancellation()
            observeWork?(.canonicalRead)
            guard let canonical = store.loadSession(id: input.sourceID),
                  canonical.messages.count == closedUI.count
                    || canonical.messages.count == closedUI.count + 1,
                  Array(canonical.messages.prefix(closedUI.count)) == closedUI,
                  canonical.projectID == input.localSession.projectID,
                  canonical.lineageIdentity == Self.lineage(of: input.localSession) else {
                return nil
            }
            if canonical.messages.count > closedUI.count {
                guard canonical.messages.last?.role == .assistant,
                      canonical.messages.last == initialPlaceholder
                        || canonical.messages.last == currentProjection.last else {
                    return nil
                }
            }
            try Task.checkCancellation()
            return AgentLoopChatEngine.AutomaticCompactionSource(session: canonical,
                closedPrefixCount: closedUI.count, uiRevision: input.uiRevision)
        }
        let source = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        return source
    }
}
