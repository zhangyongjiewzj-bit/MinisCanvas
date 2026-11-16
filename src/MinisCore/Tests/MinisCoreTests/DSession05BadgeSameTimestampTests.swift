import Foundation
import Testing
@testable import MinisCore

/// D-SESSION-05 (DEV-333 option B): a mark-read projection that keeps the same
/// session identity and the same `updatedAt` as the preceding unread projection
/// must still clear the badge (unread -> idle). Late events and the
/// failed/running priorities remain fail-closed.
///
/// Expected RED/GREEN matrix against base 31972c886:
///   (i)  sameTimestampUnreadThenReadClearsBadge — RED before fix, GREEN after.
///   (ii) lateLowerTimestampEventStillRejected   — GREEN before and after (regression guard).
///   (iii) sameTimestampIdleToUnreadStillAccepted — GREEN before and after (regression guard).
struct DSession05BadgeSameTimestampTests {

    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSession05-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func identicalProjectionDoesNotRewriteTheBadgeLedger() throws {
        let dir = try makeTempDir("IdenticalProjection")
        defer { try? FileManager.default.removeItem(at: dir) }
        let badge = SessionBadgeStore(directory: dir)
        let identity = SessionBadgeStore.SessionIdentity(sessionID: "dsess05-idempotent")
        let initialTime = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try #require(badge.project(
            identity: identity, source: .running, updatedAt: initialTime
        ))
        let file = dir.appendingPathComponent("badges.json")
        let originalData = try Data(contentsOf: file)
        let originalInode = try #require(
            FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
        )

        #expect(badge.project(identity: identity, source: .running, updatedAt: initialTime) == first)
        let repeatedInode = try #require(
            FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
        )
        #expect(repeatedInode == originalInode)
        #expect(try Data(contentsOf: file) == originalData)

        let laterTime = initialTime.addingTimeInterval(60)
        #expect(badge.project(identity: identity, source: .running, updatedAt: laterTime)?.updatedAt == laterTime)
        #expect(try Data(contentsOf: file) != originalData)
        #expect(SessionBadgeStore(directory: dir).snapshot(for: identity.sessionID)?.updatedAt == laterTime)
    }

    @Test func sameTimestampUnreadThenReadClearsBadge() throws {
        let dir = try makeTempDir("ClearSameTs")
        defer { try? FileManager.default.removeItem(at: dir) }
        let badge = SessionBadgeStore(directory: dir)
        let sid = "dsess05-clear"
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        // Same identity shape as the sidebar projection (no revision/turn).
        let identity = SessionBadgeStore.SessionIdentity(sessionID: sid)
        _ = badge.project(identity: identity, source: .idle, unread: true, updatedAt: t0)
        #expect(badge.status(for: sid) == .unread)
        let cleared = badge.project(identity: identity, source: .idle, unread: false, updatedAt: t0)
        #expect(cleared?.status == .idle)
        #expect(badge.status(for: sid) == .idle)
    }

    @Test func lateLowerTimestampEventStillRejected() throws {
        let dir = try makeTempDir("LateReject")
        defer { try? FileManager.default.removeItem(at: dir) }
        let badge = SessionBadgeStore(directory: dir)
        let sid = "dsess05-late"
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(60)
        let identity = SessionBadgeStore.SessionIdentity(sessionID: sid)
        _ = badge.project(identity: identity, source: .idle, unread: true, updatedAt: t1)
        #expect(badge.status(for: sid) == .unread)
        let late = badge.project(identity: identity, source: .idle, unread: false, updatedAt: t0)
        #expect(late == nil)
        #expect(badge.status(for: sid) == .unread)
    }

    @Test func sameTimestampIdleToUnreadStillAccepted() throws {
        let dir = try makeTempDir("PromoteSameTs")
        defer { try? FileManager.default.removeItem(at: dir) }
        let badge = SessionBadgeStore(directory: dir)
        let sid = "dsess05-promote"
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let identity = SessionBadgeStore.SessionIdentity(sessionID: sid)
        _ = badge.project(identity: identity, source: .idle, unread: false, updatedAt: t0)
        #expect(badge.status(for: sid) == .idle)
        let promoted = badge.project(identity: identity, source: .idle, unread: true, updatedAt: t0)
        #expect(promoted?.status == .unread)
        #expect(badge.status(for: sid) == .unread)
    }
}
