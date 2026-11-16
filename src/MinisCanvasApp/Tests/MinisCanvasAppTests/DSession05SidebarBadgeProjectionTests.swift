import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Exercises the same persistent projection entry point used by the actual row.
/// No SwiftUI mounting, shared badge store, or transcript persistence attachment.
@Suite("D-SESSION-05 persistent sidebar badge consumer 352")
@MainActor
struct DSession05SidebarBadgeProjectionTests {
    private struct Fixture {
        let profile: RuntimeIsolationProfile
        let chat: ChatStore
        let badgeDirectory: URL
        let badges: SessionBadgeStore
    }

    private func makeFixture() throws -> Fixture {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "sidebar-badge352", canvasRuntimeState: .disabled
        )
        #expect(!profile.allowsExternalNetwork)
        let chat = ChatStore(
            preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager()
        )
        // attachPersistence constructs a default shared badge manager; do not
        // call it even with a temporary transcript store in this fixture.
        let directory = profile.rootDirectory.appendingPathComponent("sidebar-badges", isDirectory: true)
        print("SIDEBAR352_ISOLATED_PROFILE=" + profile.rootDirectory.path)
        return Fixture(profile: profile, chat: chat, badgeDirectory: directory,
                       badges: SessionBadgeStore(directory: directory))
    }

    private func presentation(
        _ item: ChatStore.SessionListItem,
        in badges: SessionBadgeStore
    ) -> SessionBadgeStore.Presentation {
        SessionSidebarView.sessionBadgePresentation(for: item, source: item.indicator, store: badges)
    }

    private func row(
        id: UUID,
        unread: Bool,
        at timestamp: Date,
        execution: ChatStore.ExecutionSnapshot? = nil
    ) -> ChatStore.SessionListItem {
        ChatStore.SessionListItem(
            session: ChatThread(id: id, title: "synthetic sidebar row",
                                createdAt: timestamp, updatedAt: timestamp, unread: unread),
            execution: execution
        )
    }

    @Test func markingTwoRowsThenOpeningOnePreservesOtherBadgeAcrossBadgeReload() throws {
        let fixture = try makeFixture()
        let chat = fixture.chat
        let sessionA = try #require(chat.activeSessionID)
        let sessionB = chat.applyNewSession(title: "synthetic unread keeper")
        #expect(chat.activeSessionID == sessionB)
        chat.setUnread(true, sessionID: sessionA)
        chat.setUnread(true, sessionID: sessionB)
        let before = chat.sessionList
        let beforeA = try #require(before.first { $0.id == sessionA })
        let beforeB = try #require(before.first { $0.id == sessionB })
        #expect(presentation(beforeA, in: fixture.badges).systemImageName == "circle.fill")
        #expect(presentation(beforeB, in: fixture.badges).systemImageName == "circle.fill")

        #expect(chat.applySwitchSession(id: sessionA), "a target switch must really succeed")
        #expect(chat.activeSessionID == sessionA)
        let after = chat.sessionList
        let afterA = try #require(after.first { $0.id == sessionA })
        let afterB = try #require(after.first { $0.id == sessionB })
        #expect(!afterA.session.unread)
        #expect(afterB.session.unread)
        let shownA = presentation(afterA, in: fixture.badges)
        let shownB = presentation(afterB, in: fixture.badges)
        #expect(shownA.status == .idle)
        #expect(shownA.systemImageName == "circle")
        #expect(shownA.accessibilityLabel == "会话空闲")
        #expect(shownB.status == .unread)
        #expect(shownB.systemImageName == "circle.fill")
        #expect(shownB.accessibilityLabel == "会话有未读消息")

        // Reload only this explicit badge authority. This does not claim a
        // full transcript/ChatStore remount through attachPersistence.
        let reloaded = SessionBadgeStore(directory: fixture.badgeDirectory)
        #expect(reloaded.snapshot(for: sessionA.uuidString)?.status == .idle)
        #expect(reloaded.snapshot(for: sessionB.uuidString)?.status == .unread)
        #expect(presentation(afterA, in: reloaded) == shownA)
        #expect(presentation(afterB, in: reloaded) == shownB)
    }

    @Test func equalSourceTimeMarkUnreadThenReadUsesRealConsumer() throws {
        let fixture = try makeFixture()
        let id = UUID()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let idle = row(id: id, unread: false, at: t0)
        let unread = row(id: id, unread: true, at: t0)
        #expect(presentation(idle, in: fixture.badges).status == .idle)
        let marked = presentation(unread, in: fixture.badges)
        #expect(marked.status == .unread)
        #expect(marked.systemImageName == "circle.fill")
        let opened = presentation(idle, in: fixture.badges)
        #expect(opened.status == .idle)
        #expect(opened.systemImageName == "circle")
        #expect(opened.identity == marked.identity)
        #expect(fixture.badges.snapshot(for: id.uuidString)?.updatedAt == t0)
    }

    @Test func olderReadSourceCannotClearNewerUnreadThroughConsumer() throws {
        let fixture = try makeFixture()
        let id = UUID()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(60)
        let newerUnread = row(id: id, unread: true, at: t1)
        let oldRead = row(id: id, unread: false, at: t0)
        let accepted = presentation(newerUnread, in: fixture.badges)
        let before = try #require(fixture.badges.snapshot(for: id.uuidString))
        #expect(presentation(oldRead, in: fixture.badges) == accepted)
        #expect(fixture.badges.snapshot(for: id.uuidString) == before)
        #expect(before.status == .unread)
        #expect(before.updatedAt == t1)
    }

    @Test func runningAndFailedPrioritySurviveEqualTimeIdleThroughConsumer() throws {
        let fixture = try makeFixture()
        let id = UUID()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let running = ChatStore.ExecutionSnapshot(
            sessionID: id, turnID: 7, taskID: "synthetic-task352",
            state: .running, updatedAt: t0
        )
        var idle = running
        idle.state = .idle
        var failed = running
        failed.state = .failed
        failed.failureReason = "synthetic failure"
        let runningRow = row(id: id, unread: true, at: t0, execution: running)
        let idleRow = row(id: id, unread: true, at: t0, execution: idle)
        let failedRow = row(id: id, unread: true, at: t0, execution: failed)
        let showingRunning = presentation(runningRow, in: fixture.badges)
        #expect(showingRunning.status == .running)
        #expect(showingRunning.systemImageName == "circle.dotted")
        #expect(presentation(idleRow, in: fixture.badges) == showingRunning)
        let showingFailed = presentation(failedRow, in: fixture.badges)
        #expect(showingFailed.status == .failed)
        #expect(showingFailed.systemImageName == "exclamationmark.triangle.fill")
        #expect(showingFailed.isRetryable)
        #expect(presentation(idleRow, in: fixture.badges) == showingFailed)
    }

    @Test func seededNewerIdleClassifiesOldUnreadFallbackWithoutWeakeningFence() throws {
        let fixture = try makeFixture()
        let id = UUID()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(60)
        // Artificial seed: demonstrates the conditional fallback, not a
        // naturally reachable production event sequence or product RED.
        let newerIdle = presentation(row(id: id, unread: false, at: t1), in: fixture.badges)
        let before = try #require(fixture.badges.snapshot(for: id.uuidString))
        let staleUnread = row(id: id, unread: true, at: t0)
        #expect(staleUnread.indicator == .unread)
        let observed = presentation(staleUnread, in: fixture.badges)
        #expect(observed == newerIdle)
        #expect(observed.status == .idle)
        #expect(observed.systemImageName == "circle")
        #expect(fixture.badges.snapshot(for: id.uuidString) == before)
    }

    @Test func seededForeignOwnerClassifiesFallbackWithoutReplacingItsAuthority() throws {
        let fixture = try makeFixture()
        let id = UUID()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        // Production sidebar does not currently supply these owner fields.
        // This artificial seed cannot establish a real owner-conflict bug.
        let foreign = SessionBadgeStore.SessionIdentity(
            sessionID: id.uuidString, providerID: "synthetic-provider352",
            lineageOwner: "synthetic-owner352", transcriptRevision: 2
        )
        let accepted = try #require(fixture.badges.project(identity: foreign, status: .idle, updatedAt: t0))
        let unread = row(id: id, unread: true, at: t0.addingTimeInterval(60))
        #expect(unread.indicator == .unread)
        let observed = presentation(unread, in: fixture.badges)
        #expect(observed == accepted.presentation())
        #expect(observed.identity == foreign)
        #expect(fixture.badges.snapshot(for: id.uuidString) == accepted)
    }
}
