import Foundation
import Testing
@testable import MinisCore

@Suite("D-CONC2 session-read validation / revocation / consumption", .serialized)
struct SessionReadConsumptionInterleaving2573Tests: Sendable {
    private func authorization(now: Date) -> CrossSessionReadAuthorization {
        CrossSessionReadAuthorization.issue(
            currentConversationID: "source-2573", authorizedSessionID: "target-2573",
            turnID: 73, issuedAt: now, lifetime: 60, scope: .metadata
        )
    }

    private var context: SessionReadExecutionContext {
        SessionReadExecutionContext(currentConversationID: "source-2573", turnID: 73)
    }

    @Test(arguments: [
        CrossSessionReadAuthorization.InvalidationReason.revoked,
        .stopped, .turnEnded, .conversationChanged,
    ])
    func invalidationCompletedBeforeConsumeCannotAdmit(
        reason: CrossSessionReadAuthorization.InvalidationReason
    ) async throws {
        let now = Date(timeIntervalSince1970: 73_000)
        let capability = authorization(now: now)
        // These are the exact two production methods called in SessionReadTool.
        // Freeze the allowed ordering: validation returns, another task completes
        // invalidation, then consumption begins. This proves the admission seam,
        // not that an external SessionReadTool call was paused between its lines.
        try capability.validate(targetSessionID: "target-2573", scope: .metadata,
                                context: context, now: now)
        #expect(capability.isActive)
        await Task.detached { capability.invalidate(reason: reason) }.value
        #expect(capability.invalidationReason == reason)
        #expect(!capability.isActive)
        #expect(!capability.consume(targetSessionID: "target-2573", scope: .metadata))
        #expect(!capability.consume(targetSessionID: "target-2573", scope: .metadata))
        #expect(capability.invalidationReason == reason)
    }

    @Test func realReadConsumerKeepsFreshReadAndRevocationBoundary() throws {
        let formalRoot = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let root = URL(fileURLWithPath: formalRoot, isDirectory: true)
            .appendingPathComponent("session-consumption-2573-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let store = SessionStore(directory: root)
        let manager = SessionManager(store: store, badgeStore: SessionBadgeStore(directory: root))
        try store.updateSession(ChatSession(id: "target-2573", title: "normal-projection-2573"))
        let now = Date(timeIntervalSince1970: 73_000)
        let fresh = authorization(now: now)
        let input: [String: Any] = ["session_id": "target-2573", "scope": "metadata"]
        let allowedMarker = root.appendingPathComponent("allowed-trusted-source.txt")
        let deniedMarker = root.appendingPathComponent("denied-trusted-source.txt")
        let output = try SessionReadTool.read(input: input, manager: manager,
            authorization: fresh, context: context, now: now, knownSecretsProvider: {
                try? "synthetic-allowed".write(to: allowedMarker, atomically: true, encoding: .utf8)
                return []
            })
        #expect(output.contains("normal-projection-2573"))
        #expect(FileManager.default.fileExists(atPath: allowedMarker.path))
        #expect(throws: CrossSessionReadAuthorizationError.replayed) {
            _ = try SessionReadTool.read(input: input, manager: manager,
                authorization: fresh, context: context, now: now)
        }
        let revoked = authorization(now: now)
        revoked.invalidate(reason: .revoked)
        #expect(throws: CrossSessionReadAuthorizationError.revoked) {
            _ = try SessionReadTool.read(input: input, manager: manager,
                authorization: revoked, context: context, now: now, knownSecretsProvider: {
                    try? "should-not-run".write(to: deniedMarker, atomically: true, encoding: .utf8)
                    return []
                })
        }
        #expect(!FileManager.default.fileExists(atPath: deniedMarker.path))
        #expect(manager.loadSessionIncludingArchived(id: "target-2573")?.title == "normal-projection-2573")
    }
}
