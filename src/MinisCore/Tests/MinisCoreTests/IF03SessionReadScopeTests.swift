import Foundation
import MinisCore
import Testing

@Suite("IF-03 session_read scope capability")
struct IF03SessionReadScopeTests {
    private func makeManager() throws -> (SessionManager, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("if03-session-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let store = SessionStore(directory: directory)
        let manager = SessionManager(
            store: store,
            badgeStore: SessionBadgeStore(directory: directory)
        )
        try store.updateSession(ChatSession(
            id: "target-session",
            title: "目标会话",
            messages: [LLMMessage(role: .user, content: "历史消息")]
        ))
        return (manager, directory)
    }

    @Test func capabilityBindsMetadataAndRejectsMessagesEscalation() throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 10_000)
        let authorization = CrossSessionReadAuthorization.issue(
            currentConversationID: "current-conversation",
            authorizedSessionID: "target-session",
            turnID: 7,
            issuedAt: now,
            lifetime: 60,
            scope: .metadata
        )
        let context = SessionReadExecutionContext(
            currentConversationID: "current-conversation",
            turnID: 7
        )

        let metadata = try SessionReadTool.read(
            input: ["session_id": "target-session", "scope": "metadata"],
            manager: manager,
            authorization: authorization,
            context: context,
            now: now.addingTimeInterval(1)
        )
        #expect(metadata.contains("\"scope\":\"metadata\""))

        let escalationAuthorization = CrossSessionReadAuthorization.issue(
            currentConversationID: "current-conversation",
            authorizedSessionID: "target-session",
            turnID: 7,
            issuedAt: now,
            lifetime: 60,
            scope: .metadata
        )
        #expect(throws: CrossSessionReadAuthorizationError.scopeNotAuthorized) {
            _ = try SessionReadTool.read(
                input: ["session_id": "target-session", "scope": "messages"],
                manager: manager,
                authorization: escalationAuthorization,
                context: context,
                now: now.addingTimeInterval(1)
            )
        }
    }

    @Test func capabilityBindsSourceAndRestartRevision() throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 30_000)
        let authorization = CrossSessionReadAuthorization.issue(
            currentConversationID: "current-conversation",
            authorizedSessionID: "target-session",
            turnID: 19,
            issuedAt: now,
            lifetime: 60,
            scope: .metadata,
            sourceSessionID: "source-session",
            restartRevision: "restart-1"
        )
        #expect(throws: CrossSessionReadAuthorizationError.sourceSessionMismatch) {
            _ = try SessionReadTool.read(
                input: ["session_id": "target-session", "scope": "metadata"],
                manager: manager,
                authorization: authorization,
                context: SessionReadExecutionContext(
                    currentConversationID: "current-conversation",
                    turnID: 19,
                    sourceSessionID: "other-source",
                    restartRevision: "restart-1"
                ),
                now: now.addingTimeInterval(1)
            )
        }
        #expect(throws: CrossSessionReadAuthorizationError.restartRevisionMismatch) {
            _ = try SessionReadTool.read(
                input: ["session_id": "target-session", "scope": "metadata"],
                manager: manager,
                authorization: authorization,
                context: SessionReadExecutionContext(
                    currentConversationID: "current-conversation",
                    turnID: 19,
                    sourceSessionID: "source-session",
                    restartRevision: "restart-2"
                ),
                now: now.addingTimeInterval(1)
            )
        }
    }

    @Test func successfulReadConsumesExactCapabilityRequest() throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 40_000)
        let authorization = CrossSessionReadAuthorization.issue(
            currentConversationID: "current-conversation",
            authorizedSessionID: "target-session",
            turnID: 23,
            issuedAt: now,
            lifetime: 60,
            scope: .metadata
        )
        let input: [String: Any] = [
            "session_id": "target-session",
            "scope": "metadata",
        ]
        _ = try SessionReadTool.read(
            input: input,
            manager: manager,
            authorization: authorization,
            context: SessionReadExecutionContext(
                currentConversationID: "current-conversation",
                turnID: 23
            ),
            now: now.addingTimeInterval(1)
        )
        #expect(throws: CrossSessionReadAuthorizationError.replayed) {
            _ = try SessionReadTool.read(
                input: input,
                manager: manager,
                authorization: authorization,
                context: SessionReadExecutionContext(
                    currentConversationID: "current-conversation",
                    turnID: 23
                ),
                now: now.addingTimeInterval(1)
            )
        }
    }

    @Test func capabilityRejectsWrongTurnSwitchStopAndExpiry() throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 20_000)
        func issue(
            lifetime: TimeInterval = 60
        ) -> CrossSessionReadAuthorization {
            CrossSessionReadAuthorization.issue(
                currentConversationID: "current-conversation",
                authorizedSessionID: "target-session",
                turnID: 11,
                issuedAt: now,
                lifetime: lifetime,
                scope: .messages
            )
        }
        let input: [String: Any] = [
            "session_id": "target-session",
            "scope": "messages",
        ]

        #expect(throws: CrossSessionReadAuthorizationError.turnMismatch) {
            _ = try SessionReadTool.read(
                input: input,
                manager: manager,
                authorization: issue(),
                context: SessionReadExecutionContext(
                    currentConversationID: "current-conversation",
                    turnID: 12
                ),
                now: now.addingTimeInterval(1)
            )
        }

        let switched = issue()
        #expect(throws: CrossSessionReadAuthorizationError.conversationMismatch) {
            _ = try SessionReadTool.read(
                input: input,
                manager: manager,
                authorization: switched,
                context: SessionReadExecutionContext(
                    currentConversationID: "another-conversation",
                    turnID: 11
                ),
                now: now.addingTimeInterval(1)
            )
        }
        #expect(switched.isActive == false)

        let stopped = issue()
        stopped.invalidate(reason: .stopped)
        #expect(throws: CrossSessionReadAuthorizationError.stopped) {
            _ = try SessionReadTool.read(
                input: input,
                manager: manager,
                authorization: stopped,
                context: SessionReadExecutionContext(
                    currentConversationID: "current-conversation",
                    turnID: 11,
                    isStopped: true
                ),
                now: now.addingTimeInterval(1)
            )
        }

        #expect(throws: CrossSessionReadAuthorizationError.expired) {
            _ = try SessionReadTool.read(
                input: input,
                manager: manager,
                authorization: issue(lifetime: 1),
                context: SessionReadExecutionContext(
                    currentConversationID: "current-conversation",
                    turnID: 11
                ),
                now: now.addingTimeInterval(2)
            )
        }
    }

    @Test func duplicateCapabilityIdentityCannotReplayAcrossIndependentValues() throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 50_000)
        let capabilityID = UUID()
        let first = CrossSessionReadAuthorization.issue(
            currentConversationID: "current-conversation",
            authorizedSessionID: "target-session",
            turnID: 31,
            issuedAt: now,
            lifetime: 60,
            scope: .metadata,
            capabilityID: capabilityID
        )
        let duplicate = CrossSessionReadAuthorization.issue(
            currentConversationID: "current-conversation",
            authorizedSessionID: "target-session",
            turnID: 31,
            issuedAt: now,
            lifetime: 60,
            scope: .metadata,
            capabilityID: capabilityID
        )
        #expect(first == duplicate)
        let input: [String: Any] = [
            "session_id": "target-session",
            "scope": "metadata",
        ]
        let context = SessionReadExecutionContext(
            currentConversationID: "current-conversation",
            turnID: 31
        )
        _ = try SessionReadTool.read(
            input: input,
            manager: manager,
            authorization: first,
            context: context,
            now: now
        )
        #expect(throws: CrossSessionReadAuthorizationError.replayed) {
            _ = try SessionReadTool.read(
                input: input,
                manager: manager,
                authorization: duplicate,
                context: context,
                now: now
            )
        }
    }

    @Test func invalidIdentitiesAndUnicodeAliasesFailClosed() throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 55_000)
        let input: [String: Any] = [
            "session_id": "target-session",
            "scope": "metadata",
        ]
        let context = SessionReadExecutionContext(
            currentConversationID: "current-conversation",
            turnID: 33
        )

        let invalidSource = CrossSessionReadAuthorization.issue(
            currentConversationID: "current-conversation",
            authorizedSessionID: "target-session",
            turnID: 33,
            issuedAt: now,
            lifetime: 60,
            sourceSessionID: " \t"
        )
        #expect(throws: CrossSessionReadAuthorizationError.invalidIdentity) {
            _ = try SessionReadTool.read(
                input: input,
                manager: manager,
                authorization: invalidSource,
                context: context,
                now: now
            )
        }

        let invalidTarget = CrossSessionReadAuthorization.issue(
            currentConversationID: "current-conversation",
            authorizedSessionID: " \n",
            turnID: 33,
            issuedAt: now,
            lifetime: 60
        )
        #expect(throws: CrossSessionReadAuthorizationError.invalidIdentity) {
            _ = try SessionReadTool.read(
                input: input,
                manager: manager,
                authorization: invalidTarget,
                context: context,
                now: now
            )
        }

        #expect(throws: ToolExecutorError.missingParameter("session_id")) {
            _ = try SessionReadTool.read(
                input: ["session_id": " \n", "scope": "metadata"],
                manager: manager,
                authorization: CrossSessionReadAuthorization.issue(
                    currentConversationID: "current-conversation",
                    authorizedSessionID: "target-session",
                    turnID: 33,
                    issuedAt: now,
                    lifetime: 60
                ),
                context: context,
                now: now
            )
        }
        #expect(throws: ToolExecutorError.invalidParameter("scope")) {
            _ = try SessionReadTool.read(
                input: ["session_id": "target-session", "scope": " \t"],
                manager: manager,
                authorization: CrossSessionReadAuthorization.issue(
                    currentConversationID: "current-conversation",
                    authorizedSessionID: "target-session",
                    turnID: 33,
                    issuedAt: now,
                    lifetime: 60
                ),
                context: context,
                now: now
            )
        }

        // Unicode canonical equivalents are distinct session identities at
        // this boundary; do not normalize or case-fold them into a grant.
        let composed = "target-\u{00E9}"
        let decomposed = "target-e\u{301}"
        let unicodeAuthorization = CrossSessionReadAuthorization.issue(
            currentConversationID: "current-conversation",
            authorizedSessionID: decomposed,
            turnID: 33,
            issuedAt: now,
            lifetime: 60
        )
        #expect(throws: CrossSessionReadAuthorizationError.sessionNotAuthorized) {
            _ = try SessionReadTool.read(
                input: ["session_id": composed, "scope": "metadata"],
                manager: manager,
                authorization: unicodeAuthorization,
                context: context,
                now: now
            )
        }
    }

    @Test func clockRollbackCannotConsumeCapabilityBeforeIssueTime() throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        let issuedAt = Date(timeIntervalSince1970: 60_000)
        let authorization = CrossSessionReadAuthorization.issue(
            currentConversationID: "current-conversation",
            authorizedSessionID: "target-session",
            turnID: 37,
            issuedAt: issuedAt,
            lifetime: 60,
            scope: .metadata
        )
        let input: [String: Any] = [
            "session_id": "target-session",
            "scope": "metadata",
        ]
        let context = SessionReadExecutionContext(
            currentConversationID: "current-conversation",
            turnID: 37
        )
        #expect(throws: CrossSessionReadAuthorizationError.notYetValid) {
            _ = try SessionReadTool.read(
                input: input,
                manager: manager,
                authorization: authorization,
                context: context,
                now: issuedAt.addingTimeInterval(-1)
            )
        }
        _ = try SessionReadTool.read(
            input: input,
            manager: manager,
            authorization: authorization,
            context: context,
            now: issuedAt
        )
    }
}
