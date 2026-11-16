import Foundation
import Testing
@testable import MinisCore

struct WP3MemoryExternalAuthorizationTests {
    @Test
    func scopeFilterSeparatesSessionProjectAndUserReads() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = MemoryStore(directory: directory)
        let session = MemoryScope(sessionID: "session-a", projectID: "project-a")
        let otherSession = MemoryScope(sessionID: "session-b", projectID: "project-a")

        _ = try store.addFact(
            id: "session-a",
            text: "shared memory",
            sourceSessionID: session.sessionID,
            memoryScope: session,
            ownerUserID: "user-a"
        )
        _ = try store.addFact(
            id: "session-b",
            text: "shared memory",
            sourceSessionID: otherSession.sessionID,
            memoryScope: otherSession,
            ownerUserID: "user-b"
        )
        _ = try store.addFact(
            id: "other-project",
            text: "shared memory",
            sourceSessionID: "session-c",
            memoryScope: MemoryScope(sessionID: "session-c", projectID: "project-b"),
            ownerUserID: "user-a"
        )

        #expect(try store.searchFacts(
            keywords: ["shared"],
            within: .session(session)
        ).map(\.id) == ["session-a"])
        #expect(try store.searchFacts(
            keywords: ["shared"],
            within: .project(projectID: "project-a")
        ).map(\.id).sorted() == ["session-a", "session-b"])
        #expect(try store.searchFacts(
            keywords: ["shared"],
            within: .user(userID: "user-a")
        ).map(\.id).sorted() == ["other-project", "session-a"])

        let injector = MemoryInjector(store: store)
        #expect(try injector.relevantFacts(
            for: "shared",
            in: .user(userID: "user-b")
        ).map(\.id) == ["session-b"])
    }

    @Test
    func invalidScopeFilterAndLegacyFactsFailClosed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = MemoryStore(directory: directory)
        _ = try store.addFact("legacy shared memory", sourceSessionID: "legacy")

        #expect(MemoryScopeFilter.project(projectID: " ").isValid == false)
        #expect(MemoryScopeFilter.user(userID: "").isValid == false)
        #expect(try store.searchFacts(
            keywords: ["shared"],
            within: .session(MemoryScope(sessionID: "legacy", projectID: "project-a"))
        ).isEmpty)
        #expect(try store.searchFacts(
            keywords: ["shared"],
            within: .user(userID: "legacy-user")
        ).isEmpty)
    }

    @Test
    func proposalLifecycleRequiresReviewAndReceiptBeforeActivation() throws {
        let scope = MemoryScope(sessionID: "session-a", projectID: "project-a")
        let proposal = MemoryProposal(
            proposalID: "proposal-1",
            target: MemoryReadScope(
                memoryScope: scope,
                content: .metadata
            ),
            requestedMemoryScope: .session,
            sourceRef: "external:source-a",
            contentDigest: "digest-1",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )

        let reviewed = try #require(MemoryProposalLifecycle.review(proposal))
        let approved = try #require(MemoryProposalLifecycle.approve(reviewed))
        let approval = try #require(MemoryReceipt.from(approved, actor: "user"))
        let activeReceipt = try #require(MemoryProposalLifecycle.activate(approval))
        let rolledBack = try #require(
            MemoryProposalLifecycle.rollback(activeReceipt, reason: "scope changed")
        )
        #expect(rolledBack.state == .rolledBack)
    }

    @Test
    func rejectionProducesReceiptAndCannotActivate() throws {
        let scope = MemoryScope(sessionID: "session-a", projectID: "project-a")
        let proposal = MemoryProposal(
            proposalID: "proposal-reject",
            target: MemoryReadScope(memoryScope: scope, content: .messages),
            requestedMemoryScope: .session,
            sourceRef: "external:source-a",
            contentDigest: "digest-reject",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let reviewed = try #require(MemoryProposalLifecycle.review(proposal))
        let rejected = try #require(MemoryProposalLifecycle.reject(reviewed))
        let receipt = try #require(MemoryReceipt.from(rejected, actor: "user"))

        #expect(receipt.state == .rejected)
        #expect(MemoryProposalLifecycle.activate(receipt) == nil)
    }

    @Test
    func externalAuthorizationSeparatesMetadataAndMessages() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let scope = MemoryScope(sessionID: "session-a", projectID: "project-a")
        let source = TestExternalSource(sourceID: "source-a")
        let metadata = MemoryReadScope(memoryScope: scope, content: .metadata)
        let messages = MemoryReadScope(memoryScope: scope, content: .messages)
        let authorization = ExternalSourceReadAuthorization(
            grantID: "grant-1",
            sourceID: source.sourceID,
            scopes: [metadata],
            expiresAt: now.addingTimeInterval(60)
        )

        try ExternalSourceReadAuthorizer.validate(
            ExternalSourceReadRequest(
                sourceID: source.sourceID,
                scope: metadata,
                authorization: authorization
            ),
            source: source,
            now: now
        )
        #expect(throws: ExternalSourceAuthorizationError.scopeNotGranted) {
            try ExternalSourceReadAuthorizer.validate(
                ExternalSourceReadRequest(
                    sourceID: source.sourceID,
                    scope: messages,
                    authorization: authorization
                ),
                source: source,
                now: now
            )
        }
    }

    @Test(arguments: [
        ExternalSourceAuthorizationError.unauthorized,
        .expired,
        .revoked,
        .sourceMismatch,
        .sourceUnavailable,
        .invalidScope
    ])
    func externalAuthorizationFailsClosed(
        _ expected: ExternalSourceAuthorizationError
    ) {
        let now = Date(timeIntervalSince1970: 1_000)
        let validScope = MemoryScope(sessionID: "session-a", projectID: "project-a")
        let source = TestExternalSource(
            sourceID: "source-a",
            availability: expected == .sourceUnavailable ? .unavailable : .available
        )
        let requestedScope = expected == .invalidScope
            ? MemoryScope(sessionID: "", projectID: "project-a")
            : validScope
        let authorization = ExternalSourceReadAuthorization(
            grantID: "grant-1",
            sourceID: expected == .sourceMismatch ? "other-source" : source.sourceID,
            scopes: [MemoryReadScope(memoryScope: validScope, content: .metadata)],
            expiresAt: expected == .expired
                ? now.addingTimeInterval(-1)
                : now.addingTimeInterval(60),
            revokedAt: expected == .revoked ? now : nil
        )
        let request = ExternalSourceReadRequest(
            sourceID: expected == .sourceMismatch ? "other-source" : source.sourceID,
            scope: MemoryReadScope(memoryScope: requestedScope, content: .metadata),
            authorization: expected == .unauthorized ? nil : authorization
        )

        #expect(throws: expected) {
            try ExternalSourceReadAuthorizer.validate(request, source: source, now: now)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WP3MemoryExternalAuthorization-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct TestExternalSource: ExternalSourceReadOnly, Sendable {
    let sourceID: String
    let availability: ExternalSourceAvailability

    init(
        sourceID: String,
        availability: ExternalSourceAvailability = .available
    ) {
        self.sourceID = sourceID
        self.availability = availability
    }
}
