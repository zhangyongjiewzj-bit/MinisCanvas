import Foundation
import Testing
@testable import MinisCore

/// Behavioural contract tests for `ExternalSessionLocalStoreAdapter`: the local-store
/// read-side implementation of the `ExistingAgentSessionAdapter` seam.
///
/// Every fixture session is a synthetic `ChatSession` written into a fresh temporary
/// `SessionStore` directory; no real user session content appears here or in any
/// artefact. The tests exercise real reads against that store (list/read/status),
/// assert fail-closed grant enforcement through the real
/// `ExternalSessionAuthorizationLedgerV1`, and never substitute a static comment for
/// an executed assertion.
@Suite("External-session local-store adapter read side")
struct ExternalSessionLocalStoreAdapterTests {
    private static let sourceID = ExternalSessionSourceID(rawValue: "local-store-a")
    private static let otherSourceID = ExternalSessionSourceID(rawValue: "local-store-b")
    private static let profileID = ExternalSessionProfileID(rawValue: "profile-test")
    private static let otherProfileID = ExternalSessionProfileID(rawValue: "profile-other")
    private static let now = Date(timeIntervalSince1970: 150)

    private struct Fixture {
        let directory: URL
        let store: SessionStore
        let ledger: ExternalSessionAuthorizationLedgerV1
        let adapter: ExternalSessionLocalStoreAdapter
        let authCounter = AuthCounter()

        func makeReadGrant(
            target: ExternalSessionReadTargetV1,
            scopes: Set<ExternalSessionReadScopeV1>,
            sourceID: ExternalSessionSourceID = ExternalSessionLocalStoreAdapterTests.sourceID,
            profileID: ExternalSessionProfileID = ExternalSessionLocalStoreAdapterTests.profileID,
            issuedAt: Date = ExternalSessionLocalStoreAdapterTests.now.addingTimeInterval(-50),
            lifetime: TimeInterval = 100
        ) async throws -> ExternalSessionReadGrantV1 {
            let index = authCounter.next()
            return try await ledger.issueReadGrant(
                authorizationID: ExternalSessionAuthorizationID(
                    rawValue: "test-auth-\(sourceID.rawValue)-\(index)"
                ),
                sourceID: sourceID,
                profileID: profileID,
                target: target,
                scopes: scopes,
                issuedAt: issuedAt,
                lifetime: lifetime
            )
        }
    }

    private final class AuthCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
    }

    private static func makeFixture(clock: @escaping @Sendable () -> Date = { now }) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCore-ExtSessionAdapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let adapter = ExternalSessionLocalStoreAdapter(
            sourceID: sourceID,
            profileID: profileID,
            hostID: "test-host",
            store: store,
            authorizationLedger: ledger,
            clock: clock
        )
        return Fixture(directory: directory, store: store, ledger: ledger, adapter: adapter)
    }

    /// Synthetic transcript used across the read/status tests:
    /// 0 user, 1 assistant(tool-call), 2 tool, 3 assistant, 4 user, 5 assistant.
    private static func seedConversation(
        in fixture: Fixture,
        id: String,
        updatedAt: Date,
        projectID: String? = nil
    ) throws -> ChatSession {
        let session = ChatSession(
            id: id,
            title: "synthetic \(id)",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: updatedAt,
            messages: [
                LLMMessage(role: .user, content: "SYNTHETIC-PROMPT-ALPHA \(id) question"),
                LLMMessage(role: .assistant, content: "SYNTHETIC-REPLY-BETA \(id) thinking"),
                LLMMessage(role: .tool, content: "SYNTHETIC-TOOLRESULT-GAMMA \(id) output", toolCallID: "call-1"),
                LLMMessage(role: .assistant, content: "SYNTHETIC-REPLY-DELTA \(id) answer"),
                LLMMessage(role: .user, content: "SYNTHETIC-PROMPT-EPSILON \(id) follow-up"),
                LLMMessage(role: .assistant, content: "Bearer SYNTHETICTOKENVALUE123456 for \(id)"),
            ],
            transcriptRevision: 6,
            projectID: projectID,
            modelID: "synthetic-model",
            providerTypeRaw: "synthetic-provider"
        )
        try fixture.store.updateSession(session)
        return session
    }

    private func threadQuery(
        cursor: ExternalSessionCursorV1 = .beginning,
        limit: UInt16 = 10,
        projectID: ExternalSessionProjectID? = nil,
        sourceID: ExternalSessionSourceID = ExternalSessionLocalStoreAdapterTests.sourceID
    ) -> ExternalSessionThreadQueryV1 {
        ExternalSessionThreadQueryV1(
            sourceID: sourceID,
            projectID: projectID,
            cursor: cursor,
            limit: limit
        )
    }

    private func readRequest(
        thread: String,
        cursor: ExternalSessionCursorV1 = .beginning,
        limit: UInt16 = 100,
        turnID: ExternalSessionTurnID? = nil,
        sourceID: ExternalSessionSourceID = ExternalSessionLocalStoreAdapterTests.sourceID
    ) -> ExternalSessionReadRequestV1 {
        ExternalSessionReadRequestV1(
            sourceID: sourceID,
            threadID: ExternalSessionThreadID(rawValue: thread),
            turnID: turnID,
            cursor: cursor,
            limit: limit
        )
    }

    // MARK: - listThreads maps the real store

    @Test("listThreads returns real store sessions with deterministic pagination")
    func listThreadsReturnsRealStoreRecords() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try Self.seedConversation(in: fixture, id: "beta", updatedAt: Date(timeIntervalSince1970: 200))
        _ = try Self.seedConversation(in: fixture, id: "gamma", updatedAt: Date(timeIntervalSince1970: 200))
        _ = try Self.seedConversation(in: fixture, id: "alpha", updatedAt: Date(timeIntervalSince1970: 100))

        let grant = try await fixture.makeReadGrant(target: .source(Self.sourceID), scopes: [.metadata])
        let page1 = try await fixture.adapter.listThreads(
            query: threadQuery(cursor: .beginning, limit: 2),
            readGrant: grant
        )
        #expect(page1.sourceID == Self.sourceID)
        // Deterministic order: updatedAt desc, then id asc.
        #expect(page1.threads.map(\.threadID.rawValue) == ["beta", "gamma"])
        #expect(page1.nextCursor == ExternalSessionCursorV1(rawValue: "local:offset:2"))
        #expect(page1.observedCursor == ExternalSessionCursorV1(rawValue: "local:size:3"))
        let thread = page1.threads[0]
        #expect(thread.title == "synthetic beta")
        #expect(thread.status == .completed)
        #expect(thread.readable)
        #expect(thread.sourceCursor == ExternalSessionCursorV1(rawValue: "local:rev:6"))
        #expect(thread.updatedAt == Date(timeIntervalSince1970: 200))

        let page2 = try await fixture.adapter.listThreads(
            query: threadQuery(cursor: try #require(page1.nextCursor), limit: 2),
            readGrant: grant
        )
        #expect(page2.threads.map(\.threadID.rawValue) == ["alpha"])
        #expect(page2.nextCursor == nil)
    }

    @Test("listThreads project filter only exposes matching store records")
    func listThreadsProjectFiltering() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try Self.seedConversation(in: fixture, id: "in-project", updatedAt: Date(timeIntervalSince1970: 200), projectID: "proj-1")
        _ = try Self.seedConversation(in: fixture, id: "no-project", updatedAt: Date(timeIntervalSince1970: 100))

        let sourceGrant = try await fixture.makeReadGrant(target: .source(Self.sourceID), scopes: [.metadata])
        let all = try await fixture.adapter.listThreads(query: threadQuery(), readGrant: sourceGrant)
        #expect(Set(all.threads.map(\.threadID.rawValue)) == ["in-project", "no-project"])

        let projectGrant = try await fixture.makeReadGrant(
            target: .project(ExternalSessionProjectID(rawValue: "proj-1")),
            scopes: [.metadata]
        )
        let filtered = try await fixture.adapter.listThreads(
            query: threadQuery(projectID: ExternalSessionProjectID(rawValue: "proj-1")),
            readGrant: projectGrant
        )
        #expect(filtered.threads.map(\.threadID.rawValue) == ["in-project"])
        #expect(filtered.threads.first?.projectID == ExternalSessionProjectID(rawValue: "proj-1"))

        // A project-scoped grant must not open a different project's threads.
        await #expect(throws: ExternalSessionLocalStoreAdapter.Failure.targetMismatch) {
            try await fixture.adapter.listThreads(
                query: threadQuery(projectID: ExternalSessionProjectID(rawValue: "proj-2")),
                readGrant: projectGrant
            )
        }
    }

    // MARK: - read delivers real, redacted, bounded content

    @Test("read surfaces store transcript content as redacted bounded events and turns")
    func readDeliversRealRedactedContent() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try Self.seedConversation(in: fixture, id: "conv-1", updatedAt: Date(timeIntervalSince1970: 200))

        let grant = try await fixture.makeReadGrant(
            target: .thread(ExternalSessionThreadID(rawValue: "conv-1")),
            scopes: [.messages]
        )
        let page = try await fixture.adapter.read(
            request: readRequest(thread: "conv-1"),
            readGrant: grant
        )
        #expect(page.threadID == ExternalSessionThreadID(rawValue: "conv-1"))
        #expect(page.events.count == 6)
        #expect(page.nextCursor == nil)
        #expect(page.observedCursor == ExternalSessionCursorV1(rawValue: "local:rev:6"))

        // Real synthetic content is readable through the adapter (not a stub).
        #expect(page.events[0].payload.kind == "user")
        #expect(page.events[0].payload.summary.contains("SYNTHETIC-PROMPT-ALPHA conv-1 question"))
        #expect(page.events[2].payload.kind == "tool")
        #expect(page.events[2].payload.summary.contains("SYNTHETIC-TOOLRESULT-GAMMA"))
        #expect(page.events[1].turnID == ExternalSessionTurnID(rawValue: "local-turn-0"))
        #expect(page.events[4].turnID == ExternalSessionTurnID(rawValue: "local-turn-4"))
        // Store-relative path pattern only, never an absolute filesystem path.
        #expect(page.events[0].sourceRef.hasPrefix("local-store:sessions/conv-1.json#message:"))
        #expect(!page.events[0].sourceRef.hasPrefix("/"))
        // Sequences are dense and monotone over the message index.
        #expect(page.events.map(\.sequence) == Array(UInt64(1)...UInt64(6)))

        // Turns segment at user anchors with factual statuses plus real model metadata.
        #expect(page.turns.count == 2)
        let turn = page.turns[0]
        #expect(turn.turnID == ExternalSessionTurnID(rawValue: "local-turn-0"))
        #expect(turn.status == .succeeded)
        #expect(turn.modelID == "synthetic-model")
        #expect(turn.providerID == "synthetic-provider")
        #expect(page.turns[1].status == .succeeded)

        // Credential-shaped substrings are masked at the boundary (app-wide redactor):
        // the Bearer label survives, the token value never does.
        let lastEvent = try #require(page.events.last)
        #expect(lastEvent.payload.summary.contains("Bearer"))
        #expect(!lastEvent.payload.summary.contains("SYNTHETICTOKENVALUE123456"))
    }

    @Test("read truncates oversized content to the bounded summary budget")
    func readBoundsLargeContent() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let longContent = String(repeating: "字synthetic", count: 300)
        let session = ChatSession(
            id: "big",
            title: "big",
            updatedAt: Date(timeIntervalSince1970: 200),
            messages: [LLMMessage(role: .user, content: longContent)],
            transcriptRevision: 1
        )
        try fixture.store.updateSession(session)

        let grant = try await fixture.makeReadGrant(
            target: .thread(ExternalSessionThreadID(rawValue: "big")),
            scopes: [.messages]
        )
        let page = try await fixture.adapter.read(
            request: readRequest(thread: "big"),
            readGrant: grant
        )
        let summary = try #require(page.events.first?.payload.summary)
        #expect(summary.count <= ExternalSessionLocalStoreAdapter.summaryMaxCharacters + 1)
        #expect(summary.hasSuffix("…"))
    }

    @Test("cursor pagination keeps turn/sequence consistent across pages")
    func cursorPaginationIsSequenceConsistent() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try Self.seedConversation(in: fixture, id: "conv-2", updatedAt: Date(timeIntervalSince1970: 200))

        let grant = try await fixture.makeReadGrant(
            target: .thread(ExternalSessionThreadID(rawValue: "conv-2")),
            scopes: [.messages]
        )
        var cursor = ExternalSessionCursorV1.beginning
        var collected: [UInt64] = []
        var seenEventIDs: Set<String> = []
        for _ in 0..<10 {
            let page = try await fixture.adapter.read(
                request: readRequest(thread: "conv-2", cursor: cursor, limit: 2),
                readGrant: grant
            )
            collected.append(contentsOf: page.events.map(\.sequence))
            for event in page.events {
                #expect(seenEventIDs.insert(event.eventID.rawValue).inserted)
            }
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        #expect(collected == [1, 2, 3, 4, 5, 6])

        // A cursor the adapter cannot own fails closed rather than restarting.
        await #expect(throws: ExternalSessionLocalStoreAdapter.Failure.invalidCursor("bogus")) {
            try await fixture.adapter.read(
                request: readRequest(thread: "conv-2", cursor: ExternalSessionCursorV1(rawValue: "bogus")),
                readGrant: grant
            )
        }
        // A page-wide request with limit zero is rejected.
        await #expect(throws: ExternalSessionLocalStoreAdapter.Failure.invalidLimit(0)) {
            try await fixture.adapter.read(
                request: readRequest(thread: "conv-2", limit: 0),
                readGrant: grant
            )
        }
    }

    // MARK: - status

    @Test("status reports thread/turn observations consistent with read")
    func statusMatchesReadObservations() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try Self.seedConversation(in: fixture, id: "conv-3", updatedAt: Date(timeIntervalSince1970: 200))

        let grant = try await fixture.makeReadGrant(
            target: .thread(ExternalSessionThreadID(rawValue: "conv-3")),
            scopes: [.status]
        )
        let threadStatus = try await fixture.adapter.status(
            target: ExternalSessionStatusTargetV1(
                sourceID: Self.sourceID,
                threadID: ExternalSessionThreadID(rawValue: "conv-3")
            ),
            readGrant: grant
        )
        #expect(threadStatus.threadStatus == .completed)
        #expect(threadStatus.turnStatus == .succeeded)
        #expect(threadStatus.latestSequence == 6)
        #expect(threadStatus.observedCursor == ExternalSessionCursorV1(rawValue: "local:rev:6"))

        let messagesGrant = try await fixture.makeReadGrant(
            target: .thread(ExternalSessionThreadID(rawValue: "conv-3")),
            scopes: [.messages]
        )
        let page = try await fixture.adapter.read(
            request: readRequest(thread: "conv-3"),
            readGrant: messagesGrant
        )
        // Sequence/cursor coherence: latestSequence == number of messages, and the
        // observed cursor matches a full read of the same transcript.
        #expect(threadStatus.latestSequence == UInt64(page.events.count))
        #expect(threadStatus.observedCursor == page.observedCursor)

        let turnStatus = try await fixture.adapter.status(
            target: ExternalSessionStatusTargetV1(
                sourceID: Self.sourceID,
                threadID: ExternalSessionThreadID(rawValue: "conv-3"),
                turnID: ExternalSessionTurnID(rawValue: "local-turn-4")
            ),
            readGrant: grant
        )
        #expect(turnStatus.turnStatus == .succeeded)
        #expect(turnStatus.turnID == ExternalSessionTurnID(rawValue: "local-turn-4"))
    }

    @Test("source-level status exposes only the bounded store observation")
    func sourceLevelStatus() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try Self.seedConversation(in: fixture, id: "solo", updatedAt: Date(timeIntervalSince1970: 200))

        let grant = try await fixture.makeReadGrant(target: .source(Self.sourceID), scopes: [.status])
        let status = try await fixture.adapter.status(
            target: ExternalSessionStatusTargetV1(sourceID: Self.sourceID),
            readGrant: grant
        )
        #expect(status.threadID == nil)
        #expect(status.threadStatus == nil)
        #expect(status.latestSequence == nil)
        #expect(status.observedCursor == ExternalSessionCursorV1(rawValue: "local:size:1"))
    }

    // MARK: - Fail-closed grant enforcement

    @Test("a grant never issued through the ledger fails closed")
    func neverIssuedGrantFailsClosed() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try Self.seedConversation(in: fixture, id: "conv-4", updatedAt: Date(timeIntervalSince1970: 200))

        // Hand-assembled from valid-looking components but never minted by the ledger.
        let forged = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "never-issued"),
            sourceID: Self.sourceID,
            profileID: Self.profileID,
            target: .source(Self.sourceID),
            scopes: Set([.metadata, .messages, .status]),
            issuedAt: Self.now.addingTimeInterval(-50),
            expiresAt: Self.now.addingTimeInterval(50),
            revocationEpoch: 0
        )
        await #expect(throws: ExternalSessionLocalStoreAdapter.Failure.grantNotAuthorized(revocationEpoch: 0)) {
            try await fixture.adapter.read(
                request: readRequest(thread: "conv-4"),
                readGrant: forged
            )
        }
        await #expect(throws: ExternalSessionLocalStoreAdapter.Failure.grantNotAuthorized(revocationEpoch: 0)) {
            try await fixture.adapter.listThreads(
                query: threadQuery(),
                readGrant: forged
            )
        }
    }

    @Test("expired and not-yet-valid grants fail closed on every read entry point")
    func lifetimeGrantsFailClosed() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try Self.seedConversation(in: fixture, id: "conv-5", updatedAt: Date(timeIntervalSince1970: 200))

        let expired = try await fixture.makeReadGrant(
            target: .source(Self.sourceID),
            scopes: Set([.metadata, .messages, .status]),
            issuedAt: Date(timeIntervalSince1970: 10),
            lifetime: 20
        )
        #expect(expired.expiresAt < Self.now)
        await #expect(throws: ExternalSessionLocalStoreAdapter.Failure.grantExpired) {
            try await fixture.adapter.listThreads(query: threadQuery(), readGrant: expired)
        }
        await #expect(throws: ExternalSessionLocalStoreAdapter.Failure.grantExpired) {
            try await fixture.adapter.read(
                request: readRequest(thread: "conv-5"),
                readGrant: expired
            )
        }
        await #expect(throws: ExternalSessionLocalStoreAdapter.Failure.grantExpired) {
            try await fixture.adapter.status(
                target: ExternalSessionStatusTargetV1(sourceID: Self.sourceID),
                readGrant: expired
            )
        }

        let future = try await fixture.makeReadGrant(
            target: .source(Self.sourceID),
            scopes: Set([.metadata, .messages, .status]),
            issuedAt: Self.now.addingTimeInterval(10),
            lifetime: 100
        )
        await #expect(throws: ExternalSessionLocalStoreAdapter.Failure.grantNotYetValid) {
            try await fixture.adapter.listThreads(query: threadQuery(), readGrant: future)
        }
    }

    @Test("revoked epoch invalidates previously issued grants for the pair only")
    func revokedEpochFailsClosed() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try Self.seedConversation(in: fixture, id: "conv-6", updatedAt: Date(timeIntervalSince1970: 200))

        let grant = try await fixture.makeReadGrant(
            target: .source(Self.sourceID),
            scopes: Set([.metadata, .messages, .status])
        )
        // Sanity: active before revocation.
        let page = try await fixture.adapter.listThreads(query: threadQuery(), readGrant: grant)
        #expect(page.threads.count == 1)

        let newEpoch = await fixture.ledger.revoke(sourceID: Self.sourceID, profileID: Self.profileID)
        #expect(newEpoch == 1)
        await #expect(throws: ExternalSessionLocalStoreAdapter.Failure.grantNotAuthorized(revocationEpoch: 0)) {
            try await fixture.adapter.read(
                request: readRequest(thread: "conv-6"),
                readGrant: grant
            )
        }
        await #expect(throws: ExternalSessionLocalStoreAdapter.Failure.grantNotAuthorized(revocationEpoch: 0)) {
            try await fixture.adapter.status(
                target: ExternalSessionStatusTargetV1(
                    sourceID: Self.sourceID,
                    threadID: ExternalSessionThreadID(rawValue: "conv-6")
                ),
                readGrant: grant
            )
        }

        // Re-issuing at the new epoch restores access for the same pair.
        let refreshed = try await fixture.makeReadGrant(
            target: .source(Self.sourceID),
            scopes: Set([.metadata, .messages, .status])
        )
        #expect(refreshed.revocationEpoch == 1)
        let restored = try await fixture.adapter.read(
            request: readRequest(thread: "conv-6"),
            readGrant: refreshed
        )
        #expect(restored.events.count == 6)
    }

    @Test("cross-source and cross-profile grants stay invisible to this adapter")
    func crossSourceInvisibility() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try Self.seedConversation(in: fixture, id: "conv-7", updatedAt: Date(timeIntervalSince1970: 200))

        // Another source's grant (even a validly issued one) never opens this source.
        let otherSourceGrant = try await fixture.makeReadGrant(
            target: .source(Self.otherSourceID),
            scopes: Set([.metadata, .messages, .status]),
            sourceID: Self.otherSourceID
        )
        await #expect(throws: ExternalSessionLocalStoreAdapter.Failure.grantSourceMismatch(Self.otherSourceID)) {
            try await fixture.adapter.listThreads(query: threadQuery(), readGrant: otherSourceGrant)
        }
        // Even with a same-source grant, a query aimed at another source is refused.
        let ownGrant = try await fixture.makeReadGrant(
            target: .source(Self.sourceID),
            scopes: Set([.metadata, .messages, .status])
        )
        await #expect(throws: ExternalSessionLocalStoreAdapter.Failure.targetMismatch) {
            try await fixture.adapter.listThreads(
                query: threadQuery(sourceID: Self.otherSourceID),
                readGrant: ownGrant
            )
        }
        await #expect(throws: ExternalSessionLocalStoreAdapter.Failure.requestedSourceMismatch(Self.otherSourceID)) {
            try await fixture.adapter.read(
                request: readRequest(thread: "conv-7", sourceID: Self.otherSourceID),
                readGrant: ownGrant
            )
        }
        // Another profile's grant fails closed even when it names this source.
        let otherProfileGrant = try await fixture.makeReadGrant(
            target: .source(Self.sourceID),
            scopes: Set([.metadata, .messages, .status]),
            profileID: Self.otherProfileID
        )
        await #expect(throws: ExternalSessionLocalStoreAdapter.Failure.grantProfileMismatch(Self.otherProfileID)) {
            try await fixture.adapter.status(
                target: ExternalSessionStatusTargetV1(sourceID: Self.sourceID),
                readGrant: otherProfileGrant
            )
        }
    }

    @Test("scope and thread-target mismatches fail closed")
    func scopeAndTargetFailClosed() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try Self.seedConversation(in: fixture, id: "conv-8", updatedAt: Date(timeIntervalSince1970: 200))
        _ = try Self.seedConversation(in: fixture, id: "conv-9", updatedAt: Date(timeIntervalSince1970: 100))

        // Metadata scope does not grant message reads.
        let metadataOnly = try await fixture.makeReadGrant(
            target: .source(Self.sourceID),
            scopes: [.metadata]
        )
        await #expect(throws: ExternalSessionLocalStoreAdapter.Failure.scopeNotGranted(.messages)) {
            try await fixture.adapter.read(
                request: readRequest(thread: "conv-8"),
                readGrant: metadataOnly
            )
        }
        await #expect(throws: ExternalSessionLocalStoreAdapter.Failure.scopeNotGranted(.status)) {
            try await fixture.adapter.status(
                target: ExternalSessionStatusTargetV1(sourceID: Self.sourceID),
                readGrant: metadataOnly
            )
        }
        // A thread-scoped grant cannot read a different thread.
        let threadScoped = try await fixture.makeReadGrant(
            target: .thread(ExternalSessionThreadID(rawValue: "conv-8")),
            scopes: [.messages]
        )
        await #expect(throws: ExternalSessionLocalStoreAdapter.Failure.targetMismatch) {
            try await fixture.adapter.read(
                request: readRequest(thread: "conv-9"),
                readGrant: threadScoped
            )
        }
        // Unknown threads fail closed after grant validation (source-scoped grant so
        // the target check cannot mask the lookup failure).
        let sourceScoped = try await fixture.makeReadGrant(
            target: .source(Self.sourceID),
            scopes: [.messages]
        )
        await #expect(
            throws: ExternalSessionLocalStoreAdapter.Failure.unknownThread(
                ExternalSessionThreadID(rawValue: "missing")
            )
        ) {
            try await fixture.adapter.read(
                request: readRequest(thread: "missing"),
                readGrant: sourceScoped
            )
        }
    }

    // MARK: - Control stays a separate lane

    @Test("control yields the terminal unsupported receipt without touching sessions")
    func controlIsUnsupportedTerminal() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try Self.seedConversation(in: fixture, id: "conv-10", updatedAt: Date(timeIntervalSince1970: 200))

        // No control grant is ever minted by this lane; the terminal receipt needs none.
        let placeholderGrant = ExternalSessionControlGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "control-unused"),
            sourceID: Self.sourceID,
            profileID: Self.profileID,
            target: .thread(ExternalSessionThreadID(rawValue: "conv-10")),
            operations: [.interrupt],
            issuedAt: Self.now,
            expiresAt: Self.now.addingTimeInterval(60),
            revocationEpoch: 0
        )
        let receipt = try await fixture.adapter.control(
            request: ExternalSessionControlRequestV1(
                sourceID: Self.sourceID,
                threadID: ExternalSessionThreadID(rawValue: "conv-10"),
                operation: .interrupt,
                expectedCursor: .beginning,
                idempotencyKey: "unused-in-this-lane"
            ),
            controlGrant: placeholderGrant
        )
        #expect(receipt.outcome == .unsupported)
        #expect(receipt.operation == .interrupt)
        #expect(receipt.operationID == nil)
        // The adapter never advertises a control capability.
        #expect(fixture.adapter.source.capabilities.isDisjoint(with: [
            .resume, .fork, .steer, .interrupt, .approval,
        ]))
    }
}
