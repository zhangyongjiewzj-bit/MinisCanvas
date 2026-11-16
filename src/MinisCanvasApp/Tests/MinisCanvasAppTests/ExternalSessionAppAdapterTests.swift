import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class ExternalSessionAdapterSpy: ExistingAgentSessionAdapter, @unchecked Sendable {
    let source: ExternalSessionSourceV1
    private let lock = NSLock()
    private var recordedCalls: [String] = []

    init(source: ExternalSessionSourceV1) {
        self.source = source
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    func listThreads(
        query: ExternalSessionThreadQueryV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionThreadPageV1 {
        record("list:\(query.sourceID.rawValue):\(query.limit)")
        return ExternalSessionThreadPageV1(
            sourceID: source.sourceID,
            threads: [],
            observedCursor: query.cursor
        )
    }

    func read(
        request: ExternalSessionReadRequestV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionReadPageV1 {
        record("read:\(request.threadID.rawValue):\(request.limit)")
        return ExternalSessionReadPageV1(
            sourceID: source.sourceID,
            threadID: request.threadID,
            turns: [],
            events: [],
            observedCursor: request.cursor
        )
    }

    func status(
        target: ExternalSessionStatusTargetV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionStatusV1 {
        record("status:\(target.threadID?.rawValue ?? "source")")
        return ExternalSessionStatusV1(
            sourceID: source.sourceID,
            threadID: target.threadID,
            turnID: target.turnID,
            threadStatus: .active,
            observedCursor: .beginning
        )
    }

    func control(
        request: ExternalSessionControlRequestV1,
        controlGrant: ExternalSessionControlGrantV1
    ) async throws -> ExternalSessionControlReceiptV1 {
        record("control:\(request.operation.rawValue)")
        return ExternalSessionControlReceiptV1(
            sourceID: source.sourceID,
            threadID: request.threadID,
            turnID: request.turnID,
            operation: request.operation,
            outcome: .accepted,
            sourceCursor: request.expectedCursor
        )
    }

    private func record(_ call: String) {
        lock.lock()
        recordedCalls.append(call)
        lock.unlock()
    }
}

private final class ExternalProjectMembershipReadProbe: ExistingAgentSessionAdapter,
    ExternalSessionProjectMembershipVerifier, @unchecked Sendable {
    let source: ExternalSessionSourceV1
    private let lock = NSLock()
    private var member = false
    private var flipDuringRead = false
    private var reads = 0

    init(source: ExternalSessionSourceV1) { self.source = source }
    func setMembership(_ value: Bool, flipDuringRead: Bool = false) {
        lock.lock()
        member = value
        self.flipDuringRead = flipDuringRead
        lock.unlock()
    }
    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }
    func contains(threadID: ExternalSessionThreadID, projectID: ExternalSessionProjectID) async throws -> Bool {
        lock.withLock {
            member && threadID.rawValue == "thread-member" && projectID.rawValue == "project-member"
        }
    }
    func listThreads(query: ExternalSessionThreadQueryV1,
                     readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionThreadPageV1 {
        ExternalSessionThreadPageV1(sourceID: source.sourceID, threads: [], observedCursor: query.cursor)
    }
    func read(request: ExternalSessionReadRequestV1,
              readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionReadPageV1 {
        lock.withLock {
            reads += 1
            if flipDuringRead { member = false }
        }
        return ExternalSessionReadPageV1(
            sourceID: source.sourceID, threadID: request.threadID, turns: [], events: [],
            messageChunks: [ExternalSessionMessageChunkV1(
                sourceID: source.sourceID, threadID: request.threadID, messageID: "message-1",
                role: "assistant", chunkIndex: 0, text: "allowed body", isLastChunk: true,
                sourceRef: "synthetic:message-1"
            )], observedCursor: request.cursor
        )
    }
    func status(target: ExternalSessionStatusTargetV1,
                readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionStatusV1 {
        ExternalSessionStatusV1(sourceID: source.sourceID, threadID: target.threadID,
                                turnID: target.turnID, observedCursor: .beginning)
    }
    func control(request: ExternalSessionControlRequestV1,
                 controlGrant: ExternalSessionControlGrantV1) async throws -> ExternalSessionControlReceiptV1 {
        ExternalSessionControlReceiptV1(sourceID: source.sourceID, threadID: request.threadID,
            turnID: request.turnID, operation: request.operation, outcome: .unsupported,
            sourceCursor: request.expectedCursor)
    }
}

@Suite("External project body grant membership")
struct ExternalProjectMembershipConsumerTests {
    @Test func verifiesMembershipBeforeAndAfterBodyRead() async throws {
        let sourceID = ExternalSessionSourceID(rawValue: "synthetic-codex")
        let profileID = ExternalSessionProfileID(rawValue: "synthetic-profile")
        let threadID = ExternalSessionThreadID(rawValue: "thread-member")
        let projectID = ExternalSessionProjectID(rawValue: "project-member")
        let source = ExternalSessionSourceV1(sourceID: sourceID, kind: .codex,
            adapterVersion: "synthetic/1", profileID: profileID, hostID: "isolated",
            capabilities: [.readMessages], authState: .authorized)
        let probe = ExternalProjectMembershipReadProbe(source: source)
        let adapter = ExternalSessionAppAdapter(implementation: probe,
            clock: { Date(timeIntervalSince1970: 200) })
        let grant = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "project-read"),
            sourceID: sourceID, profileID: profileID, target: .project(projectID),
            scopes: [.messages], issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 300), revocationEpoch: 0)
        let request = ExternalSessionReadRequestV1(sourceID: sourceID, threadID: threadID, limit: 10)

        await #expect(throws: ExternalSessionAppAdapterError.targetMismatch) {
            _ = try await adapter.read(request: request, readGrant: grant)
        }
        #expect(probe.readCount == 0)
        probe.setMembership(true)
        let page = try await adapter.read(request: request, readGrant: grant)
        #expect(page.messageChunks.map(\.text) == ["allowed body"])
        #expect(probe.readCount == 1)
        probe.setMembership(true, flipDuringRead: true)
        await #expect(throws: ExternalSessionAppAdapterError.targetMismatch) {
            _ = try await adapter.read(request: request, readGrant: grant)
        }
        #expect(probe.readCount == 2)
    }
}

@Suite("External existing-session App adapter")
struct ExternalSessionAppAdapterTests {
    @Test
    func forwardsAuthorizedOperationsAndRejectsUnboundGrants() async throws {
        let sourceID = ExternalSessionSourceID(rawValue: "codex-local")
        let profileID = ExternalSessionProfileID(rawValue: "profile-a")
        let projectID = ExternalSessionProjectID(rawValue: "project-a")
        let threadID = ExternalSessionThreadID(rawValue: "thread-a")
        let issuedAt = Date(timeIntervalSince1970: 100)
        let now = Date(timeIntervalSince1970: 200)
        let source = ExternalSessionSourceV1(
            sourceID: sourceID,
            kind: .codex,
            adapterVersion: "test",
            profileID: profileID,
            hostID: "local",
            capabilities: [
                .readMetadata, .readMessages, .status, .resume, .interrupt,
            ],
            authState: .authorized
        )
        let spy = ExternalSessionAdapterSpy(source: source)
        let adapter = ExternalSessionAppAdapter(
            implementation: spy,
            clock: { now }
        )
        let listGrant = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-list"),
            sourceID: sourceID,
            profileID: profileID,
            target: .project(projectID),
            scopes: [.metadata],
            issuedAt: issuedAt,
            expiresAt: Date(timeIntervalSince1970: 300),
            revocationEpoch: 0
        )
        let readGrant = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-thread"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.messages],
            issuedAt: issuedAt,
            expiresAt: Date(timeIntervalSince1970: 300),
            revocationEpoch: 0
        )
        let statusGrant = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-status"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.status],
            issuedAt: issuedAt,
            expiresAt: Date(timeIntervalSince1970: 300),
            revocationEpoch: 0
        )
        let controlGrant = ExternalSessionControlGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "control"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            operations: [.resume],
            issuedAt: issuedAt,
            expiresAt: Date(timeIntervalSince1970: 300),
            revocationEpoch: 0
        )

        let threadPage = try await adapter.listThreads(
            query: ExternalSessionThreadQueryV1(
                sourceID: sourceID,
                projectID: projectID,
                limit: 10
            ),
            readGrant: listGrant
        )
        #expect(threadPage.sourceID == sourceID)

        let readPage = try await adapter.read(
            request: ExternalSessionReadRequestV1(
                sourceID: sourceID,
                threadID: threadID,
                limit: 10
            ),
            readGrant: readGrant
        )
        #expect(readPage.threadID == threadID)

        let status = try await adapter.status(
            target: ExternalSessionStatusTargetV1(
                sourceID: sourceID,
                threadID: threadID
            ),
            readGrant: statusGrant
        )
        #expect(status.threadStatus == ExternalSessionThreadStatusV1.active)

        let controlRequest = ExternalSessionControlRequestV1(
            sourceID: sourceID,
            threadID: threadID,
            operation: .resume,
            expectedCursor: .beginning,
            idempotencyKey: "resume-1"
        )
        let receipt = try await adapter.control(
            request: controlRequest,
            controlGrant: controlGrant
        )
        #expect(receipt.operation == ExternalSessionControlOperationV1.resume)
        #expect(spy.calls == [
            "list:codex-local:10",
            "read:thread-a:10",
            "status:thread-a",
            "control:resume",
        ])

        let expiredGrant = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "expired"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.messages],
            issuedAt: issuedAt,
            expiresAt: Date(timeIntervalSince1970: 199),
            revocationEpoch: 0
        )
        await #expect(throws: ExternalSessionAppAdapterError.grantExpired) {
            _ = try await adapter.read(
                request: ExternalSessionReadRequestV1(
                    sourceID: sourceID,
                    threadID: threadID,
                    limit: 10
                ),
                readGrant: expiredGrant
            )
        }

        let interruptRequest = ExternalSessionControlRequestV1(
            sourceID: sourceID,
            threadID: threadID,
            operation: .interrupt,
            expectedCursor: .beginning,
            idempotencyKey: "interrupt-1"
        )
        await #expect(throws: ExternalSessionAppAdapterError.operationNotGranted(.interrupt)) {
            _ = try await adapter.control(
                request: interruptRequest,
                controlGrant: controlGrant
            )
        }
        #expect(spy.calls.count == 4)
    }
}
