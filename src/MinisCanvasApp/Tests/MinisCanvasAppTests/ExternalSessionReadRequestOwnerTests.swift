import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private actor HeldLedgerResponse {
    private var continuation: CheckedContinuation<Void, Never>?

    func awaitRelease() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func isWaiting() -> Bool { continuation != nil }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private enum HeldReadError: Error { case late }

/// Synthetic adapter holds the real protocol call at an await boundary. No
/// source directory or user session is touched by this regression probe.
private struct HeldLedgerAdapter: ExistingAgentSessionAdapter {
    let source: ExternalSessionSourceV1
    let gate: HeldLedgerResponse
    let failsRead: Bool

    func listThreads(
        query: ExternalSessionThreadQueryV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionThreadPageV1 {
        await gate.awaitRelease()
        return ExternalSessionThreadPageV1(
            sourceID: source.sourceID, threads: [], observedCursor: query.cursor
        )
    }

    func read(
        request: ExternalSessionReadRequestV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionReadPageV1 {
        await gate.awaitRelease()
        if failsRead { throw HeldReadError.late }
        return ExternalSessionReadPageV1(
            sourceID: source.sourceID, threadID: request.threadID,
            turns: [], events: [], observedCursor: request.cursor
        )
    }

    func status(
        target: ExternalSessionStatusTargetV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionStatusV1 { throw CancellationError() }

    func control(
        request: ExternalSessionControlRequestV1,
        controlGrant: ExternalSessionControlGrantV1
    ) async throws -> ExternalSessionControlReceiptV1 { throw CancellationError() }
}

@Suite("D-CONC2 LedgerView request publication ownership")
@MainActor
struct ExternalSessionReadRequestOwnerTests {
    private var sourceA: ExternalSessionSourceID { .init(rawValue: "synthetic-a") }
    private var sourceB: ExternalSessionSourceID { .init(rawValue: "synthetic-b") }
    private var threadA: ExternalSessionThreadID { .init(rawValue: "thread-a") }
    private var threadB: ExternalSessionThreadID { .init(rawValue: "thread-b") }
    private var cursor: ExternalSessionCursorV1 { .init(rawValue: "opaque-next") }

    private func adapter(
        sourceID: ExternalSessionSourceID,
        gate: HeldLedgerResponse,
        failsRead: Bool = false
    ) -> HeldLedgerAdapter {
        HeldLedgerAdapter(
            source: ExternalSessionSourceV1(
                sourceID: sourceID, kind: .codex, adapterVersion: "synthetic",
                profileID: .init(rawValue: "synthetic-profile"), hostID: "synthetic-host",
                capabilities: [.readMessages, .status], authState: .authorized
            ),
            gate: gate, failsRead: failsRead
        )
    }

    private func grant(sourceID: ExternalSessionSourceID) -> ExternalSessionReadGrantV1 {
        ExternalSessionReadGrantV1(
            authorizationID: .init(rawValue: "synthetic-grant"),
            sourceID: sourceID, profileID: .init(rawValue: "synthetic-profile"),
            target: .source(sourceID), scopes: [.metadata, .messages],
            issuedAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 10_000), revocationEpoch: 0
        )
    }

    @Test func lateDiscoveryCannotOverwriteNewSourceEvenAfterABASelection() async throws {
        let owner = ExternalSessionReadRequestOwner()
        let held = HeldLedgerResponse()
        let adapter = adapter(sourceID: sourceA, gate: held)
        owner.open(sourceID: sourceA)
        let old = try #require(owner.beginDiscovery(sourceID: sourceA, cursor: .beginning))
        var displayed = ""
        let lateResponse = Task { @MainActor in
            let page = try await adapter.listThreads(
                query: ExternalSessionThreadQueryV1(
                    sourceID: sourceA, cursor: .beginning, limit: 50
                ), readGrant: grant(sourceID: sourceA)
            )
            if owner.mayPublish(old, selectedSourceID: sourceA,
                                displayedThreadID: nil, expectedCursor: nil) {
                displayed = page.sourceID.rawValue
            }
        }
        for _ in 0..<100 {
            if await held.isWaiting() { break }
            await Task.yield()
        }
        try #require(await held.isWaiting())
        owner.switchSource(sourceB)
        let newer = try #require(owner.beginDiscovery(sourceID: sourceB, cursor: .beginning))
        #expect(owner.mayPublish(newer, selectedSourceID: sourceB,
                                 displayedThreadID: nil, expectedCursor: nil))
        displayed = "new-b"
        owner.switchSource(sourceA)
        await held.release()
        try await lateResponse.value
        #expect(displayed == "new-b")
        #expect(!owner.mayPublish(old, selectedSourceID: sourceA,
                                  displayedThreadID: nil, expectedCursor: nil))
    }

    @Test func paginationRequiresTheCurrentOpaqueCursorAndRequestGeneration() throws {
        let owner = ExternalSessionReadRequestOwner()
        owner.open(sourceID: sourceA)
        let first = try #require(owner.beginDiscovery(sourceID: sourceA, cursor: .beginning))
        let page = try #require(owner.beginDiscovery(sourceID: sourceA, cursor: cursor))
        #expect(!owner.mayPublish(first, selectedSourceID: sourceA,
                                  displayedThreadID: nil, expectedCursor: nil))
        #expect(!owner.mayPublish(page, selectedSourceID: sourceA,
                                  displayedThreadID: nil, expectedCursor: nil))
        #expect(owner.mayPublish(page, selectedSourceID: sourceA,
                                 displayedThreadID: nil, expectedCursor: cursor))
        _ = owner.beginDiscovery(sourceID: sourceA, cursor: cursor)
        #expect(!owner.mayPublish(page, selectedSourceID: sourceA,
                                  displayedThreadID: nil, expectedCursor: cursor))
    }

    @Test func lateReadAndFailureLoseOwnershipOnThreadSwitchOrClose() async throws {
        let owner = ExternalSessionReadRequestOwner()
        let held = HeldLedgerResponse()
        let adapter = adapter(sourceID: sourceA, gate: held, failsRead: true)
        owner.open(sourceID: sourceA)
        owner.selectThread(threadA)
        let old = try #require(owner.beginRead(
            sourceID: sourceA, threadID: threadA, cursor: .beginning
        ))
        var published = false
        let lateFailure = Task { @MainActor in
            do {
                _ = try await adapter.read(
                    request: ExternalSessionReadRequestV1(
                        sourceID: sourceA, threadID: threadA,
                        cursor: .beginning, limit: 50
                    ), readGrant: grant(sourceID: sourceA)
                )
            } catch {
                published = owner.mayPublish(old, selectedSourceID: sourceA,
                                              displayedThreadID: threadA, expectedCursor: nil)
            }
        }
        for _ in 0..<100 {
            if await held.isWaiting() { break }
            await Task.yield()
        }
        try #require(await held.isWaiting())
        owner.selectThread(threadB)
        let current = try #require(owner.beginRead(
            sourceID: sourceA, threadID: threadB, cursor: .beginning
        ))
        #expect(owner.mayPublish(current, selectedSourceID: sourceA,
                                 displayedThreadID: threadB, expectedCursor: nil))
        owner.close()
        await held.release()
        await lateFailure.value
        #expect(!published)
        #expect(!owner.mayPublish(current, selectedSourceID: sourceA,
                                  displayedThreadID: threadB, expectedCursor: nil))
        owner.open(sourceID: sourceA)
        #expect(!owner.mayPublish(old, selectedSourceID: sourceA,
                                  displayedThreadID: threadA, expectedCursor: nil))
    }

    @Test func readPaginationStaysBoundToSourceThreadAndCursor() throws {
        let owner = ExternalSessionReadRequestOwner()
        owner.open(sourceID: sourceA)
        owner.selectThread(threadA)
        let page = try #require(owner.beginRead(sourceID: sourceA,
                                                threadID: threadA, cursor: cursor))
        #expect(!owner.mayPublish(page, selectedSourceID: sourceB,
                                  displayedThreadID: threadA, expectedCursor: cursor))
        #expect(!owner.mayPublish(page, selectedSourceID: sourceA,
                                  displayedThreadID: threadB, expectedCursor: cursor))
        #expect(!owner.mayPublish(page, selectedSourceID: sourceA,
                                  displayedThreadID: threadA, expectedCursor: nil))
        #expect(owner.mayPublish(page, selectedSourceID: sourceA,
                                 displayedThreadID: threadA, expectedCursor: cursor))
    }

    @Test func heldDiscoveryClickLosesOwnershipBeforeTaskStartEvenAfterSourceABA() async throws {
        let owner = ExternalSessionReadRequestOwner()
        let heldStart = HeldLedgerResponse()
        owner.open(sourceID: sourceA)
        // The production button calls beginDiscovery at the tap, before it
        // schedules Task. Hold that Task until the picker changes A→B→A.
        let tapped = try #require(owner.beginDiscovery(sourceID: sourceA, cursor: .beginning))
        let delayedStart = Task { @MainActor in
            await heldStart.awaitRelease()
            return owner.mayPublish(tapped, selectedSourceID: sourceA,
                                    displayedThreadID: nil, expectedCursor: nil)
        }
        for _ in 0..<100 {
            if await heldStart.isWaiting() { break }
            await Task.yield()
        }
        try #require(await heldStart.isWaiting())
        owner.switchSource(sourceB)
        owner.switchSource(sourceA)
        let current = try #require(owner.beginDiscovery(sourceID: sourceA, cursor: .beginning))
        // The newer click starts first; the older scheduled Task starts last.
        #expect(owner.mayPublish(current, selectedSourceID: sourceA,
                                 displayedThreadID: nil, expectedCursor: nil))
        await heldStart.release()
        #expect(!(await delayedStart.value), "the old tap must not reach the adapter")
    }

    @Test func heldKnownThreadClickCannotReplaceNewerTextOrPaginationIntent() async throws {
        let owner = ExternalSessionReadRequestOwner()
        let heldStart = HeldLedgerResponse()
        owner.open(sourceID: sourceA)
        // The View trims and captures thread-a at the tap. Editing the field
        // before Task starts cannot change the captured request identity.
        var fieldText = " thread-a "
        let clickedThreadID = ExternalSessionThreadID(
            rawValue: fieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        owner.selectThread(clickedThreadID)
        let tapped = try #require(owner.beginRead(
            sourceID: sourceA, threadID: clickedThreadID, cursor: .beginning
        ))
        let delayedStart = Task { @MainActor in
            await heldStart.awaitRelease()
            return owner.mayPublish(tapped, selectedSourceID: sourceA,
                                    displayedThreadID: nil, expectedCursor: nil)
        }
        for _ in 0..<100 {
            if await heldStart.isWaiting() { break }
            await Task.yield()
        }
        try #require(await heldStart.isWaiting())
        fieldText = "thread-b"
        let newerThreadID = ExternalSessionThreadID(rawValue: fieldText)
        owner.selectThread(newerThreadID)
        let current = try #require(owner.beginRead(
            sourceID: sourceA, threadID: newerThreadID, cursor: .beginning
        ))
        #expect(owner.mayPublish(current, selectedSourceID: sourceA,
                                 displayedThreadID: nil, expectedCursor: nil))
        await heldStart.release()
        #expect(!(await delayedStart.value))
        #expect(tapped.threadID == threadA)
        #expect(current.threadID == threadB)

        let more = try #require(owner.beginRead(
            sourceID: sourceA, threadID: threadB, cursor: cursor
        ))
        owner.switchSource(sourceB)
        #expect(!owner.mayPublish(more, selectedSourceID: sourceB,
                                  displayedThreadID: threadB, expectedCursor: cursor))
    }

    @Test func heldMoreButtonsRejectSupersededCursorBeforeTaskStart() async throws {
        let owner = ExternalSessionReadRequestOwner()
        let heldDiscovery = HeldLedgerResponse()
        owner.open(sourceID: sourceA)
        let oldMoreThreads = try #require(owner.beginDiscovery(sourceID: sourceA, cursor: cursor))
        let delayedDiscovery = Task { @MainActor in
            await heldDiscovery.awaitRelease()
            return owner.mayPublish(oldMoreThreads, selectedSourceID: sourceA,
                                    displayedThreadID: nil, expectedCursor: cursor)
        }
        for _ in 0..<100 {
            if await heldDiscovery.isWaiting() { break }
            await Task.yield()
        }
        try #require(await heldDiscovery.isWaiting())
        let newerCursor = ExternalSessionCursorV1(rawValue: "newer-opaque-next")
        let newMoreThreads = try #require(owner.beginDiscovery(
            sourceID: sourceA, cursor: newerCursor
        ))
        #expect(owner.mayPublish(newMoreThreads, selectedSourceID: sourceA,
                                 displayedThreadID: nil, expectedCursor: newerCursor))
        await heldDiscovery.release()
        #expect(!(await delayedDiscovery.value))

        let heldContent = HeldLedgerResponse()
        owner.selectThread(threadA)
        let oldMoreContent = try #require(owner.beginRead(
            sourceID: sourceA, threadID: threadA, cursor: cursor
        ))
        let delayedContent = Task { @MainActor in
            await heldContent.awaitRelease()
            return owner.mayPublish(oldMoreContent, selectedSourceID: sourceA,
                                    displayedThreadID: threadA, expectedCursor: cursor)
        }
        for _ in 0..<100 {
            if await heldContent.isWaiting() { break }
            await Task.yield()
        }
        try #require(await heldContent.isWaiting())
        let newMoreContent = try #require(owner.beginRead(
            sourceID: sourceA, threadID: threadA, cursor: newerCursor
        ))
        #expect(owner.mayPublish(newMoreContent, selectedSourceID: sourceA,
                                 displayedThreadID: threadA, expectedCursor: newerCursor))
        await heldContent.release()
        #expect(!(await delayedContent.value))
    }
}
