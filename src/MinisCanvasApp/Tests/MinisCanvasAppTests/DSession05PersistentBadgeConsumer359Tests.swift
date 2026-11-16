import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Natural producers and the original persistence/recovery path feed the
/// same badge consumer as the production row. No artificial clock/owner seed.
@Suite("D-SESSION-05 real persistent badge consumer 359")
@MainActor
struct DSession05PersistentBadgeConsumer359Tests {
    private struct Fixture {
        let profile: RuntimeIsolationProfile
        let store: SessionStore
        let badges: SessionBadgeStore
        let chat: ChatStore
        let badgeDirectory: URL
    }

    private struct Observation {
        let item: ChatStore.SessionListItem
        let presentation: SessionBadgeStore.Presentation
        let before: SessionBadgeStore.Snapshot?
        let after: SessionBadgeStore.Snapshot?
    }

    private struct Trace: Encodable {
        let stage: String
        let sessionID: String
        let activeSessionID: String?
        let menuSourceUnread: Bool
        let itemUnread: Bool
        let canonicalUnread: Bool
        let canonicalUpdatedAt: Date
        let indicator: String
        let execution: ChatStore.ExecutionSnapshot?
        let lastActivityAt: Date
        let sourceUpdatedAt: Date
        let before: SessionBadgeStore.Snapshot?
        let after: SessionBadgeStore.Snapshot?
        let presentationStatus: String
        let presentationIdentity: SessionBadgeStore.SessionIdentity
        let glyph: String
    }

    private func makeFixture() throws -> Fixture {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "persistent-sidebar359", canvasRuntimeState: .disabled
        )
        #expect(!profile.allowsExternalNetwork)
        let store = SessionStore(directory: profile.sessionDirectory)
        let badgeDirectory = profile.rootDirectory.appendingPathComponent("sidebar-badges", isDirectory: true)
        let badges = SessionBadgeStore(directory: badgeDirectory)
        let chat = try makeChat(profile: profile, store: store, badges: badges)
        print("PERSISTENT359_ISOLATED_PROFILE=" + profile.rootDirectory.path)
        return Fixture(profile: profile, store: store, badges: badges,
                       chat: chat, badgeDirectory: badgeDirectory)
    }

    private func makeChat(
        profile: RuntimeIsolationProfile, store: SessionStore, badges: SessionBadgeStore
    ) throws -> ChatStore {
        let chat = ChatStore(
            preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager()
        )
        try #require(chat.attachPersistence(store, badgeStore: badges))
        #expect(chat.sessionManager?.badgeStore === badges)
        return chat
    }

    private func observe(
        _ stage: String, sessionID: UUID, chat: ChatStore,
        store: SessionStore, badges: SessionBadgeStore
    ) throws -> Observation {
        let menuSource = try #require(chat.sessions.first { $0.id == sessionID })
        let item = try #require(chat.sessionList.first { $0.id == sessionID })
        let canonical = try #require(store.loadSession(id: sessionID.uuidString))
        #expect(item.session.id == menuSource.id)
        #expect(canonical.id == sessionID.uuidString)
        let before = badges.snapshot(for: sessionID.uuidString)
        let shown = SessionSidebarView.sessionBadgePresentation(
            for: item, source: item.indicator, store: badges
        )
        let after = badges.snapshot(for: sessionID.uuidString)
        let trace = Trace(
            stage: stage, sessionID: sessionID.uuidString,
            activeSessionID: chat.activeSessionID?.uuidString,
            menuSourceUnread: menuSource.unread, itemUnread: item.session.unread,
            canonicalUnread: canonical.unread, canonicalUpdatedAt: canonical.updatedAt,
            indicator: String(describing: item.indicator), execution: item.execution,
            lastActivityAt: item.lastActivityAt,
            sourceUpdatedAt: item.execution?.updatedAt ?? item.lastActivityAt,
            before: before, after: after, presentationStatus: shown.status.rawValue,
            presentationIdentity: shown.identity, glyph: shown.systemImageName
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try #require(String(data: try encoder.encode(trace), encoding: .utf8))
        print("PERSISTENT359_TRACE=" + json)
        #expect(item.session.unread == menuSource.unread)
        #expect(canonical.unread == menuSource.unread)
        #expect(shown.identity.sessionID == sessionID.uuidString)
        #expect(after?.identity.sessionID == sessionID.uuidString)
        return Observation(item: item, presentation: shown, before: before, after: after)
    }

    @Test func naturalIdleMarksPersistReloadAndOpeningOnlyTargetClearsBadge() throws {
        let fixture = try makeFixture()
        let chat = fixture.chat
        let sessionA = try #require(chat.activeSessionID)
        chat.appendUser("synthetic persistent A")
        let sessionB = chat.applyNewSession(title: "synthetic persistent B")
        chat.appendUser("synthetic persistent B")
        #expect(sessionA != sessionB)
        let baselineA = try observe("idle-before-A", sessionID: sessionA, chat: chat,
                                    store: fixture.store, badges: fixture.badges)
        let baselineB = try observe("idle-before-B", sessionID: sessionB, chat: chat,
                                    store: fixture.store, badges: fixture.badges)
        #expect(baselineA.item.execution == nil)
        #expect(baselineB.item.execution == nil)
        #expect(baselineA.presentation.status == .idle)
        #expect(baselineB.presentation.status == .idle)

        // Match the field precondition: A has really been opened, its row
        // consumed, and then left before the inactive menu-source mark.
        chat.switchSession(id: sessionA)
        #expect(chat.activeSessionID == sessionA)
        let openedBeforeMarkA = try observe("opened-before-mark-A", sessionID: sessionA, chat: chat,
                                           store: fixture.store, badges: fixture.badges)
        #expect(openedBeforeMarkA.presentation.status == .idle)
        #expect(openedBeforeMarkA.after?.updatedAt == baselineA.after?.updatedAt)
        chat.switchSession(id: sessionB)
        #expect(chat.activeSessionID == sessionB)
        let openedBeforeMarkB = try observe("opened-before-mark-B", sessionID: sessionB, chat: chat,
                                           store: fixture.store, badges: fixture.badges)
        #expect(openedBeforeMarkB.presentation.status == .idle)
        #expect(openedBeforeMarkB.after?.updatedAt == baselineB.after?.updatedAt)

        chat.setUnread(true, sessionID: sessionA)
        chat.setUnread(true, sessionID: sessionB)
        let markedA = try observe("marked-A", sessionID: sessionA, chat: chat,
                                 store: fixture.store, badges: fixture.badges)
        let markedB = try observe("marked-B", sessionID: sessionB, chat: chat,
                                 store: fixture.store, badges: fixture.badges)
        #expect(markedA.item.session.unread && markedB.item.session.unread)
        #expect(markedA.presentation.status == .unread)
        #expect(markedB.presentation.status == .unread)
        #expect(markedA.presentation.systemImageName == "circle.fill")
        #expect(markedB.presentation.systemImageName == "circle.fill")
        #expect(markedA.after?.updatedAt == baselineA.after?.updatedAt)
        #expect(markedB.after?.updatedAt == baselineB.after?.updatedAt)

        let reopenedStore = SessionStore(directory: fixture.profile.sessionDirectory)
        let reopenedBadges = SessionBadgeStore(directory: fixture.badgeDirectory)
        let reopened = try makeChat(profile: fixture.profile, store: reopenedStore, badges: reopenedBadges)
        let restoredA = try observe("reloaded-A", sessionID: sessionA, chat: reopened,
                                   store: reopenedStore, badges: reopenedBadges)
        let restoredB = try observe("reloaded-B", sessionID: sessionB, chat: reopened,
                                   store: reopenedStore, badges: reopenedBadges)
        #expect(restoredA.presentation == markedA.presentation)
        #expect(restoredB.presentation == markedB.presentation)
        #expect(restoredA.item.lastActivityAt == markedA.item.lastActivityAt)
        #expect(restoredB.item.lastActivityAt == markedB.item.lastActivityAt)

        // Ensure A is an actual switch target; the loader may have chosen it.
        #expect(reopened.applySwitchSession(id: sessionB))
        reopened.setUnread(true, sessionID: sessionB)
        #expect(reopened.applySwitchSession(id: sessionA))
        #expect(reopened.activeSessionID == sessionA)
        let openedA = try observe("opened-A", sessionID: sessionA, chat: reopened,
                                 store: reopenedStore, badges: reopenedBadges)
        let keptB = try observe("kept-B", sessionID: sessionB, chat: reopened,
                               store: reopenedStore, badges: reopenedBadges)
        #expect(!openedA.item.session.unread)
        #expect(openedA.presentation.status == .idle)
        #expect(openedA.presentation.systemImageName == "circle")
        #expect(keptB.item.session.unread)
        #expect(keptB.presentation.status == .unread)
        #expect(keptB.presentation.systemImageName == "circle.fill")
    }

    @Test func naturalPersistedRunningRecoveryPresentsCurrentUnreadState() throws {
        let fixture = try makeFixture()
        let sessionA = try #require(fixture.chat.activeSessionID)
        fixture.chat.appendUser("synthetic interrupted execution")
        let sessionB = fixture.chat.applyNewSession(title: "synthetic unaffected keeper")
        fixture.chat.appendUser("synthetic keeper")
        // Use the production state producer's own time. There is no provider
        // or worker running, no process termination, and no seeded badge file.
        fixture.chat.markExecutionRunning(
            sessionID: sessionA, turnID: 3, taskID: "synthetic-recovery359"
        )
        let running = try observe("running-before-reload", sessionID: sessionA,
                                  chat: fixture.chat, store: fixture.store, badges: fixture.badges)
        let runningClock = try #require(running.item.execution?.updatedAt)
        #expect(running.item.execution?.state == .running)
        #expect(running.item.execution?.turnID == 3)
        #expect(running.item.execution?.taskID == "synthetic-recovery359")
        #expect(running.presentation.status == .running)
        #expect(running.after?.updatedAt == runningClock)

        let reopenedStore = SessionStore(directory: fixture.profile.sessionDirectory)
        let reopenedBadges = SessionBadgeStore(directory: fixture.badgeDirectory)
        let reopened = try makeChat(profile: fixture.profile, store: reopenedStore, badges: reopenedBadges)
        let recovered = try #require(reopened.sessionList.first { $0.id == sessionA })
        #expect(recovered.execution?.state == .idle, "the original recovery must really migrate running")
        #expect(recovered.execution?.turnID == 3)
        #expect(recovered.execution?.taskID == "synthetic-recovery359")
        #expect(recovered.execution?.updatedAt == runningClock)
        #expect(reopened.applySwitchSession(id: sessionB))
        reopened.setUnread(true, sessionID: sessionA)
        let marked = try observe("recovered-marked-A", sessionID: sessionA, chat: reopened,
                                 store: reopenedStore, badges: reopenedBadges)
        #expect(marked.item.session.unread)
        #expect(marked.item.indicator == .unread)
        #expect(marked.item.execution?.updatedAt == runningClock)
        #expect(marked.before?.identity == running.after?.identity)
        #expect(marked.before?.updatedAt == runningClock)
        // This behavioral oracle stays unread. If the old persisted running
        // badge survives the real recovery, retain that first failure/trace;
        // do not change the assertion to classify the mismatch as PASS.
        #expect(marked.presentation.status == .unread,
                "current recovered idle+unread row must not retain the old running presentation")
        #expect(marked.presentation.systemImageName == "circle.fill")
        #expect(marked.after?.status == .unread)
        let keeper = try observe("unaffected-B", sessionID: sessionB, chat: reopened,
                                 store: reopenedStore, badges: reopenedBadges)
        #expect(!keeper.item.session.unread)
        #expect(keeper.presentation.status == .idle)
    }
}
