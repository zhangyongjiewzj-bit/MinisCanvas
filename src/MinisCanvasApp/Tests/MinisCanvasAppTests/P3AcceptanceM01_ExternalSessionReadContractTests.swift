import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private actor M01ExternalReadScript: ExistingAgentSessionAdapter {
    nonisolated let source: ExternalSessionSourceV1
    let threadPage: ExternalSessionThreadPageV1
    let readPage: ExternalSessionReadPageV1
    let statusValue: ExternalSessionStatusV1
    private var calls = 0

    init(
        source: ExternalSessionSourceV1,
        threadPage: ExternalSessionThreadPageV1,
        readPage: ExternalSessionReadPageV1,
        statusValue: ExternalSessionStatusV1
    ) {
        self.source = source
        self.threadPage = threadPage
        self.readPage = readPage
        self.statusValue = statusValue
    }

    func listThreads(
        query: ExternalSessionThreadQueryV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionThreadPageV1 {
        calls += 1
        return threadPage
    }

    func read(
        request: ExternalSessionReadRequestV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionReadPageV1 {
        calls += 1
        return readPage
    }

    func status(
        target: ExternalSessionStatusTargetV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionStatusV1 {
        calls += 1
        return statusValue
    }

    func control(
        request: ExternalSessionControlRequestV1,
        controlGrant: ExternalSessionControlGrantV1
    ) async throws -> ExternalSessionControlReceiptV1 {
        throw ExternalSessionAppAdapterError.invalidRequest
    }

    var callCount: Int { calls }
}

private enum M01ExternalReadFixture {
    static let sourceID = ExternalSessionSourceID(rawValue: "synthetic-source-a")
    static let otherSourceID = ExternalSessionSourceID(rawValue: "synthetic-source-b")
    static let profileID = ExternalSessionProfileID(rawValue: "synthetic-profile")
    static let projectID = ExternalSessionProjectID(rawValue: "synthetic-project")
    static let threadID = ExternalSessionThreadID(rawValue: "synthetic-thread-a")
    static let otherThreadID = ExternalSessionThreadID(rawValue: "synthetic-thread-b")
    static let turnID = ExternalSessionTurnID(rawValue: "synthetic-turn-a")
    static let now = Date(timeIntervalSince1970: 200)

    static func source(version: Int = 1) -> ExternalSessionSourceV1 {
        ExternalSessionSourceV1(
            schemaVersion: version,
            sourceID: sourceID,
            kind: .codex,
            adapterVersion: "synthetic-v1",
            profileID: profileID,
            hostID: "synthetic-host",
            capabilities: [.readMetadata, .readMessages, .status],
            authState: .authorized
        )
    }

    static func thread(
        version: Int = 1,
        sourceID: ExternalSessionSourceID = sourceID,
        projectID: ExternalSessionProjectID? = projectID
    ) -> ExternalSessionThreadV1 {
        ExternalSessionThreadV1(
            schemaVersion: version,
            sourceID: sourceID,
            threadID: threadID,
            projectID: projectID,
            title: "synthetic thread",
            status: .active,
            updatedAt: now,
            sourceCursor: .beginning,
            readable: true
        )
    }

    static func turn(
        version: Int = 1,
        sourceID: ExternalSessionSourceID = sourceID,
        threadID: ExternalSessionThreadID = threadID
    ) -> ExternalSessionTurnV1 {
        ExternalSessionTurnV1(
            schemaVersion: version,
            sourceID: sourceID,
            threadID: threadID,
            turnID: turnID,
            status: .running,
            sourceCursor: .beginning
        )
    }

    static func event(
        version: Int = 1,
        sourceID: ExternalSessionSourceID = sourceID,
        threadID: ExternalSessionThreadID = threadID
    ) -> ExternalSessionEventV1 {
        ExternalSessionEventV1(
            schemaVersion: version,
            eventID: ExternalSessionEventID(rawValue: "synthetic-event"),
            sourceID: sourceID,
            threadID: threadID,
            turnID: turnID,
            sequence: 1,
            sourceCursor: .beginning,
            occurredAt: now,
            required: true,
            kind: .progress,
            payload: ExternalSessionRedactedPayloadV1(kind: "synthetic", summary: "bounded"),
            sourceRef: "synthetic-only"
        )
    }

    static func script(
        sourceVersion: Int = 1,
        threadPage: ExternalSessionThreadPageV1? = nil,
        readPage: ExternalSessionReadPageV1? = nil,
        statusValue: ExternalSessionStatusV1? = nil
    ) -> M01ExternalReadScript {
        M01ExternalReadScript(
            source: source(version: sourceVersion),
            threadPage: threadPage ?? ExternalSessionThreadPageV1(
                sourceID: sourceID, threads: [thread()], observedCursor: .beginning
            ),
            readPage: readPage ?? ExternalSessionReadPageV1(
                sourceID: sourceID, threadID: threadID,
                turns: [turn()], events: [event()], observedCursor: .beginning
            ),
            statusValue: statusValue ?? ExternalSessionStatusV1(
                sourceID: sourceID, threadID: threadID, turnID: nil,
                threadStatus: .active, observedCursor: .beginning
            )
        )
    }

    static func grant(
        ledger: ExternalSessionAuthorizationLedgerV1,
        target: ExternalSessionReadTargetV1,
        scope: ExternalSessionReadScopeV1,
        authorizationID: String
    ) async throws -> ExternalSessionReadGrantV1 {
        try await ledger.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: authorizationID),
            sourceID: sourceID,
            profileID: profileID,
            target: target,
            scopes: [scope],
            issuedAt: Date(timeIntervalSince1970: 100),
            lifetime: 200
        )
    }

    static func adapter(
        _ script: M01ExternalReadScript,
        ledger: ExternalSessionAuthorizationLedgerV1
    ) -> ExternalSessionAppAdapter {
        ExternalSessionAppAdapter.production(
            implementation: script,
            clock: { now },
            authorizationLedger: ledger
        )
    }
}

@Suite("D-EXTC versioned external read boundary")
struct P3AcceptanceM01ExternalSessionReadContractTests {
    @Test func unknownInputVersionFailsBeforeProviderRead() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let script = M01ExternalReadFixture.script()
        let adapter = M01ExternalReadFixture.adapter(script, ledger: ledger)
        let grant = try await M01ExternalReadFixture.grant(
            ledger: ledger, target: .thread(M01ExternalReadFixture.threadID),
            scope: .messages, authorizationID: "read-input-version"
        )
        await #expect(throws: ExternalSessionAppAdapterError.unsupportedReadSchemaVersion(2)) {
            _ = try await adapter.read(
                request: ExternalSessionReadRequestV1(
                    schemaVersion: 2,
                    sourceID: M01ExternalReadFixture.sourceID,
                    threadID: M01ExternalReadFixture.threadID,
                    limit: 1
                ),
                readGrant: grant
            )
        }
        #expect(await script.callCount == 0)
    }

    @Test func nestedSourceAndThreadCannotEscapeAnAuthorizedRead() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let wrongEvent = M01ExternalReadFixture.event(threadID: M01ExternalReadFixture.otherThreadID)
        let script = M01ExternalReadFixture.script(readPage: ExternalSessionReadPageV1(
            sourceID: M01ExternalReadFixture.sourceID,
            threadID: M01ExternalReadFixture.threadID,
            turns: [M01ExternalReadFixture.turn()],
            events: [wrongEvent],
            observedCursor: .beginning
        ))
        let adapter = M01ExternalReadFixture.adapter(script, ledger: ledger)
        let grant = try await M01ExternalReadFixture.grant(
            ledger: ledger, target: .thread(M01ExternalReadFixture.threadID),
            scope: .messages, authorizationID: "read-nested-identity"
        )
        await #expect(throws: ExternalSessionAppAdapterError.invalidReadResponse) {
            _ = try await adapter.read(
                request: ExternalSessionReadRequestV1(
                    sourceID: M01ExternalReadFixture.sourceID,
                    threadID: M01ExternalReadFixture.threadID,
                    limit: 1
                ),
                readGrant: grant
            )
        }
        #expect(await script.callCount == 1)
    }

    @Test func listAndStatusRejectMisboundProviderValues() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let script = M01ExternalReadFixture.script(
            threadPage: ExternalSessionThreadPageV1(
                sourceID: M01ExternalReadFixture.sourceID,
                threads: [M01ExternalReadFixture.thread(sourceID: M01ExternalReadFixture.otherSourceID)],
                observedCursor: .beginning
            ),
            statusValue: ExternalSessionStatusV1(
                sourceID: M01ExternalReadFixture.sourceID,
                threadID: M01ExternalReadFixture.otherThreadID,
                threadStatus: .active,
                observedCursor: .beginning
            )
        )
        let adapter = M01ExternalReadFixture.adapter(script, ledger: ledger)
        let listGrant = try await M01ExternalReadFixture.grant(
            ledger: ledger, target: .project(M01ExternalReadFixture.projectID),
            scope: .metadata, authorizationID: "list-misbound"
        )
        await #expect(throws: ExternalSessionAppAdapterError.invalidReadResponse) {
            _ = try await adapter.listThreads(
                query: ExternalSessionThreadQueryV1(
                    sourceID: M01ExternalReadFixture.sourceID,
                    projectID: M01ExternalReadFixture.projectID,
                    limit: 1
                ),
                readGrant: listGrant
            )
        }
        let statusGrant = try await M01ExternalReadFixture.grant(
            ledger: ledger, target: .thread(M01ExternalReadFixture.threadID),
            scope: .status, authorizationID: "status-misbound"
        )
        await #expect(throws: ExternalSessionAppAdapterError.invalidReadResponse) {
            _ = try await adapter.status(
                target: ExternalSessionStatusTargetV1(
                    sourceID: M01ExternalReadFixture.sourceID,
                    threadID: M01ExternalReadFixture.threadID
                ),
                readGrant: statusGrant
            )
        }
        #expect(await script.callCount == 2)
    }

    @Test func nestedFutureVersionAndSourceVersionFailClosed() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let futureEvent = M01ExternalReadFixture.event(version: 2)
        let futureScript = M01ExternalReadFixture.script(readPage: ExternalSessionReadPageV1(
            sourceID: M01ExternalReadFixture.sourceID,
            threadID: M01ExternalReadFixture.threadID,
            turns: [M01ExternalReadFixture.turn()],
            events: [futureEvent],
            observedCursor: .beginning
        ))
        let grant = try await M01ExternalReadFixture.grant(
            ledger: ledger, target: .thread(M01ExternalReadFixture.threadID),
            scope: .messages, authorizationID: "read-future-event"
        )
        let request = ExternalSessionReadRequestV1(
            sourceID: M01ExternalReadFixture.sourceID,
            threadID: M01ExternalReadFixture.threadID,
            limit: 1
        )
        await #expect(throws: ExternalSessionAppAdapterError.unsupportedReadSchemaVersion(2)) {
            _ = try await M01ExternalReadFixture.adapter(futureScript, ledger: ledger)
                .read(request: request, readGrant: grant)
        }
        #expect(await futureScript.callCount == 1)

        let futureSource = M01ExternalReadFixture.script(sourceVersion: 2)
        await #expect(throws: ExternalSessionAppAdapterError.unsupportedReadSchemaVersion(2)) {
            _ = try await M01ExternalReadFixture.adapter(futureSource, ledger: ledger)
                .read(request: request, readGrant: grant)
        }
        #expect(await futureSource.callCount == 0)
    }

    @Test func validV1ReadAndPairRevocationKeepTheExistingBoundary() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let script = M01ExternalReadFixture.script()
        let adapter = M01ExternalReadFixture.adapter(script, ledger: ledger)
        let readGrant = try await M01ExternalReadFixture.grant(
            ledger: ledger, target: .thread(M01ExternalReadFixture.threadID),
            scope: .messages, authorizationID: "read-valid"
        )
        let request = ExternalSessionReadRequestV1(
            sourceID: M01ExternalReadFixture.sourceID,
            threadID: M01ExternalReadFixture.threadID,
            limit: 1
        )
        let page = try await adapter.read(request: request, readGrant: readGrant)
        #expect(page.events.count == 1)
        #expect(await script.callCount == 1)

        _ = await ledger.revoke(
            sourceID: M01ExternalReadFixture.sourceID,
            profileID: M01ExternalReadFixture.profileID
        )
        await #expect(throws: ExternalSessionAppAdapterError.grantRevoked) {
            _ = try await adapter.read(request: request, readGrant: readGrant)
        }
        #expect(await script.callCount == 1)
    }
}
