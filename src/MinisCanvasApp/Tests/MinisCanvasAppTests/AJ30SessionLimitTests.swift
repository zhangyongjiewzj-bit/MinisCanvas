import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - AJ-30 会话列表条目上限（超出自动归档最旧非置顶会话）

@Suite("AJ-30 会话列表条目上限")
@MainActor
struct AJ30SessionLimitTests {

    /// 新建会话并填满到上限（初始 1 个 + 追加 max-1 个）。
    @discardableResult
    private func fillToLimit(_ chat: ChatStore) -> ChatStore {
        for _ in 0..<(ChatStore.maxSessionListCount - 1) {
            chat.newSession()
        }
        return chat
    }

    @Test func newSessionArchivesOldestNonPinnedWhenOverLimit() {
        let chat = ChatStore()
        let firstID = chat.activeSessionID!

        fillToLimit(chat)
        #expect(chat.sessions.count == ChatStore.maxSessionListCount)
        #expect(chat.archivedList.isEmpty)

        // 再新建一个 → 超限 → 最旧非置顶会话被自动归档
        chat.newSession()
        #expect(chat.sessions.count == ChatStore.maxSessionListCount)
        #expect(chat.archivedList.count == 1)
        #expect(chat.archivedList.first?.session.id == firstID)
        #expect(!chat.sessions.contains { $0.id == firstID })
        // 新会话仍为活跃
        #expect(chat.activeSessionID != nil)
        #expect(chat.sessions.contains { $0.id == chat.activeSessionID })
    }

    @Test func pinnedSessionsAreProtectedFromAutoArchive() {
        let chat = ChatStore()
        let firstID = chat.activeSessionID!
        chat.setPinned(true, sessionID: firstID)

        fillToLimit(chat)
        #expect(chat.sessions.count == ChatStore.maxSessionListCount)
        #expect(chat.sessions.contains { $0.id == firstID && $0.pinned })

        // 超限时只归档非置顶；置顶会话保留
        chat.newSession()
        #expect(chat.sessions.count == ChatStore.maxSessionListCount)
        #expect(chat.sessions.contains { $0.id == firstID })
        #expect(chat.archivedList.contains { $0.session.id == firstID } == false)
        // 最旧的非置顶会话被归档
        #expect(chat.archivedList.count == 1)
    }

    @Test func autoArchivePersistsToDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AJ30LimitTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SessionStore(directory: dir)
        let chat = ChatStore()
        chat.attachPersistence(store)
        let firstID = chat.activeSessionID!

        fillToLimit(chat)
        #expect(chat.sessions.count == ChatStore.maxSessionListCount)

        chat.newSession()
        #expect(chat.sessions.count == ChatStore.maxSessionListCount)
        #expect(chat.archivedList.count == 1)

        // 磁盘：首个会话已从活动目录移入 _archive
        #expect(!store.listSessions().contains { $0.id == firstID.uuidString })
        let manager = chat.sessionManager!
        let archivedFile = manager.archiveDirectory.appendingPathComponent("\(firstID.uuidString).json")
        #expect(FileManager.default.fileExists(atPath: archivedFile.path))
    }

    enum RestoreLimitScenario: String, Sendable {
        case belowCap
        case pinnedAtCap
    }

    /// Tests the persisted producer and sidebar data consumer, without UI.
    /// The pinned case classifies cap behavior, not real field eligibility.
    @Test(arguments: [RestoreLimitScenario.belowCap, .pinnedAtCap])
    func restoredSessionThenNewSessionRespectsAutoArchiveEligibility(
        _ scenario: RestoreLimitScenario
    ) throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "archive407-" + scenario.rawValue, canvasRuntimeState: .disabled
        )
        #expect(!profile.allowsExternalNetwork)
        let directory = profile.rootDirectory.appendingPathComponent("sessions", isDirectory: true)
        let badgeDirectory = profile.rootDirectory.appendingPathComponent("badges", isDirectory: true)
        let store = SessionStore(directory: directory)
        let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(),
                             logManager: profile.makeLogManager())
        let attached = chat.attachPersistence(
            store, badgeStore: SessionBadgeStore(directory: badgeDirectory)
        )
        try #require(attached)
        if scenario == .pinnedAtCap {
            fillToLimit(chat)
            for id in chat.sessions.map(\.id) { chat.setPinned(true, sessionID: id) }
            #expect(chat.sessions.count == ChatStore.maxSessionListCount)
            #expect(chat.sessions.allSatisfy { $0.pinned })
        }
        let protectedIDs = Set(chat.sessions.map(\.id))
        chat.newSession()
        let target = try #require(chat.activeSessionID)
        chat.appendUser("synthetic archive407 persistent target")
        let manager = try #require(chat.sessionManager)
        func visibleIDs() -> Set<UUID> {
            Set(chat.sessionGroups.flatMap { $0.items }.map(\.id))
        }
        func trace(_ stage: String) throws {
            let targetThread = (chat.sessions + chat.archivedSessions).first { $0.id == target }
            let values: [String: Any] = [
                "case": scenario.rawValue, "stage": stage, "target": target.uuidString,
                "activeContainsTarget": chat.sessions.contains { $0.id == target },
                "archiveContainsTarget": chat.archivedSessions.contains { $0.id == target },
                "groupContainsTarget": visibleIDs().contains(target),
                "archiveConsumerContainsTarget": SessionSidebarArchiveConsumer
                    .visibleArchivedItems(in: chat).contains { $0.id == target },
                "activeCount": chat.sessions.count, "archivedCount": chat.archivedSessions.count,
                "diskActiveContainsTarget": store.listSessions().contains { $0.id == target.uuidString },
                "diskArchiveContainsTarget": manager.archivedSessions().contains { $0.id == target.uuidString },
                "targetPinned": targetThread?.pinned ?? false,
                "targetTime": targetThread?.updatedAt.timeIntervalSinceReferenceDate ?? -1,
            ]
            let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
            print("ARCHIVE407_TRACE=" + String(decoding: data, as: UTF8.self))
        }
        try trace("beforeArchive")
        _ = SessionSidebarArchiveConsumer.archive(
            target, in: chat, visibleActiveIDs: visibleIDs
        )
        #expect(!visibleIDs().contains(target))
        #expect(SessionSidebarArchiveConsumer.visibleArchivedItems(in: chat).map(\.id) == [target])
        #expect(!store.listSessions().contains { $0.id == target.uuidString })
        #expect(manager.archivedSessions().map(\.id) == [target.uuidString])
        try trace("archived")

        #expect(SessionSidebarArchiveConsumer.restore(
            target, in: chat, visibleActiveIDs: visibleIDs
        ) == target)
        #expect(chat.activeSessionID == target)
        #expect(visibleIDs().contains(target))
        #expect(chat.archivedSessions.isEmpty)
        #expect(store.listSessions().contains { $0.id == target.uuidString })
        #expect(manager.archivedSessions().isEmpty)
        let restoredTime = try #require(chat.sessions.first { $0.id == target }?.updatedAt)
        try trace("restoredAndActiveProtected")

        chat.newSession()
        #expect(chat.activeSessionID != target)
        let shouldAutoArchive = scenario == .pinnedAtCap
        #expect(chat.sessions.contains { $0.id == target } == !shouldAutoArchive)
        #expect(chat.archivedSessions.contains { $0.id == target } == shouldAutoArchive)
        #expect(visibleIDs().contains(target) == !shouldAutoArchive)
        #expect(SessionSidebarArchiveConsumer.visibleArchivedItems(in: chat)
            .contains { $0.id == target } == shouldAutoArchive)
        #expect(store.listSessions().contains { $0.id == target.uuidString } == !shouldAutoArchive)
        #expect(manager.archivedSessions().contains { $0.id == target.uuidString } == shouldAutoArchive)
        #expect(protectedIDs.isSubset(of: Set(chat.sessions.map(\.id))))
        if shouldAutoArchive {
            #expect(chat.sessions.count == ChatStore.maxSessionListCount + 1)
            #expect(chat.archivedSessions.map(\.id) == [target])
        }
        let finalTime = try #require((chat.sessions + chat.archivedSessions)
            .first { $0.id == target }?.updatedAt)
        #expect(finalTime == restoredTime)
        try trace("afterNewSession")

        let reloaded = ChatStore(preferencesDefaults: profile.makeUserDefaults(),
                                 logManager: profile.makeLogManager())
        let reloadAttached = reloaded.attachPersistence(
            store, badgeStore: SessionBadgeStore(directory: badgeDirectory)
        )
        try #require(reloadAttached)
        #expect(reloaded.sessions.contains { $0.id == target } == !shouldAutoArchive)
        #expect(reloaded.archivedSessions.contains { $0.id == target } == shouldAutoArchive)
        #expect(SessionSidebarArchiveConsumer.visibleArchivedItems(in: reloaded)
            .contains { $0.id == target } == shouldAutoArchive)
        #expect(Set(reloaded.sessionGroups.flatMap { $0.items }.map(\.id))
            .contains(target) == !shouldAutoArchive)
        #expect(reloaded.sessions.count == chat.sessions.count)
        #expect(reloaded.archivedSessions.count == chat.archivedSessions.count)
        let persisted = try #require(manager.loadSessionIncludingArchived(id: target.uuidString))
        #expect(persisted.messages.contains { $0.content == "synthetic archive407 persistent target" })
        #expect(persisted.updatedAt == restoredTime)
        let reloadTrace: [String: Any] = [
            "case": scenario.rawValue, "stage": "reopened", "target": target.uuidString,
            "activeContainsTarget": reloaded.sessions.contains { $0.id == target },
            "archiveContainsTarget": reloaded.archivedSessions.contains { $0.id == target },
            "activeCount": reloaded.sessions.count, "archivedCount": reloaded.archivedSessions.count,
            "persistedTargetTime": persisted.updatedAt.timeIntervalSinceReferenceDate,
        ]
        let reloadData = try JSONSerialization.data(withJSONObject: reloadTrace, options: [.sortedKeys])
        print("ARCHIVE407_TRACE=" + String(decoding: reloadData, as: UTF8.self))
    }
}
