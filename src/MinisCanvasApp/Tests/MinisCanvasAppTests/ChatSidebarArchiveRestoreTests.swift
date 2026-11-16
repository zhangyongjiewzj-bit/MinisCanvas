import Foundation
import AppKit
import SwiftUI
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("Sidebar archive, restore, and companion attachment projection", .serialized)
@MainActor
struct ChatSidebarArchiveRestoreTests {
    private func visibleActiveIDs(_ chat: ChatStore) -> Set<UUID> {
        Set(chat.sessions.map(\.id))
    }

    @Test("archive projection excludes active rows and duplicate archive identities")
    func archiveProjectionDeduplicatesCurrentStoreRows() {
        let chat = ChatStore()
        let originalID = chat.activeSessionID!
        chat.appendUser("原会话")
        let activeItem = ChatStore.SessionListItem(session: chat.sessions[0], execution: nil)

        #expect(SessionSidebarArchiveConsumer.visibleArchivedItems(
            [activeItem], activeIDs: visibleActiveIDs(chat)
        ).isEmpty)

        chat.archiveSession(id: originalID)
        let archivedItem = chat.archivedList[0]
        let projected = SessionSidebarArchiveConsumer.visibleArchivedItems(
            [archivedItem, archivedItem], activeIDs: visibleActiveIDs(chat)
        )
        #expect(projected.map(\.id) == [originalID])
        #expect(SessionSidebarArchiveConsumer.visibleArchivedItems(in: chat).map(\.id) == [originalID])
    }

    @Test("archive then restore focuses the canonical active row and preserves its content")
    func archiveRestoreFocusesRestoredSession() {
        let chat = ChatStore()
        let firstID = chat.activeSessionID!
        chat.appendUser("第一会话")
        chat.newSession()
        let secondID = chat.activeSessionID!
        chat.appendUser("第二会话")

        let afterArchive = SessionSidebarArchiveConsumer.archive(
            secondID, in: chat, visibleActiveIDs: { visibleActiveIDs(chat) }
        )
        #expect(afterArchive == firstID)
        #expect(chat.activeSessionID == firstID)
        #expect(SessionSidebarArchiveConsumer.visibleArchivedItems(in: chat).map(\.id) == [secondID])

        let afterRestore = SessionSidebarArchiveConsumer.restore(
            secondID, in: chat, visibleActiveIDs: { visibleActiveIDs(chat) }
        )
        #expect(afterRestore == secondID)
        #expect(chat.activeSessionID == secondID)
        #expect(SessionSidebarArchiveConsumer.visibleArchivedItems(in: chat).isEmpty)
        #expect(chat.messages.contains { $0.content == "第二会话" })
        #expect(chat.sessions.first(where: { $0.id == firstID })?.messages.contains {
            $0.content == "第一会话"
        } == true)
    }

    @Test("stale archive and restore actions do not mutate another session")
    func staleActionsFailClosed() {
        let chat = ChatStore()
        let activeID = chat.activeSessionID!
        chat.appendUser("保留内容")
        let missingID = UUID()

        #expect(SessionSidebarArchiveConsumer.archive(
            missingID, in: chat, visibleActiveIDs: { visibleActiveIDs(chat) }
        ) == nil)
        #expect(SessionSidebarArchiveConsumer.restore(
            missingID, in: chat, visibleActiveIDs: { visibleActiveIDs(chat) }
        ) == nil)
        #expect(chat.activeSessionID == activeID)
        #expect(chat.sessions.map(\.id) == [activeID])
        #expect(chat.messages.contains { $0.content == "保留内容" })
        #expect(chat.archivedList.isEmpty)
    }

    @Test("companion chip derives a type without losing pending or failed status")
    func companionAttachmentTypeProjection() {
        let pending = ChatAttachment(
            kind: .file, fileName: "data.json", fileType: .json, status: .pending
        )
        let failed = ChatAttachment(
            kind: .file, fileName: "data.json", fileType: .json, status: .failed
        )
        let ready = ChatAttachment(
            kind: .text, fileName: "data.json", fileType: .json,
            data: Data("{}".utf8), status: .ready
        )

        #expect(SessionSidebarAttachmentChipInfo(pending).fileName == "data.json")
        #expect(SessionSidebarAttachmentChipInfo(pending).typeLabel == "JSON")
        #expect(SessionSidebarAttachmentChipInfo(pending).statusText == "解析中")
        #expect(SessionSidebarAttachmentChipInfo(failed).typeLabel == "JSON")
        #expect(SessionSidebarAttachmentChipInfo(failed).statusText == "读取失败")
        #expect(SessionSidebarAttachmentChipInfo(ready).typeLabel == "JSON")
        #expect(SessionSidebarAttachmentChipInfo(ready).statusText == nil)
    }

    @Test("same native sidebar retires active rows on archive and restores the exact session",
          arguments: [false, true])
    func sameProcessArchiveRestoreHasCanonicalNativeActions(initiallyPinned: Bool) throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "sidebar-archive428", canvasRuntimeState: .disabled
        )
        #expect(!profile.allowsExternalNetwork)
        let store = SessionStore(directory: profile.sessionDirectory)
        let badges = SessionBadgeStore(directory: profile.rootDirectory
            .appendingPathComponent("sidebar-badges", isDirectory: true))
        let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(),
                             logManager: profile.makeLogManager())
        try #require(chat.attachPersistence(store, badgeStore: badges))
        #expect(chat.sessionManager?.badgeStore === badges)
        let companionID = try #require(chat.activeSessionID)
        chat.appendUser("保留另一个会话")
        let companionMessages = chat.messages.map(\.id)
        let companionPayload = chat.messages.filter { $0.role != .system }.map { $0.asLLMMessage() }
        let companionStableIDs = stableMessageIDs(in: companionPayload)
        let group = try #require(chat.createGroup(named: "合成归档组428"))
        chat.newSession(groupID: group.id)
        let targetID = try #require(chat.activeSessionID)
        chat.appendUser("归档恢复保持同一条消息")
        let targetMessages = chat.messages.map(\.id)
        let targetPayload = chat.messages.filter { $0.role != .system }.map { $0.asLLMMessage() }
        let targetStableIDs = stableMessageIDs(in: targetPayload)
        chat.setPinned(initiallyPinned, sessionID: targetID)

        // Reuse the existing native host lifecycle and owned public AX channel.
        // This method requires a separately granted native UI run, not headless PASS.
        let lease = NativeTestHostLifecycle.begin("SidebarArchive428")
        let controller = NSHostingController(rootView: SessionSidebarView(
            chat: chat, collapsed: false, sessionBadgeStore: badges,
            badgeDiagnosticsEnabled: false
        ))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 900),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
            NativeTestHostLifecycle.end(window)
        }
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 420, height: 900))
        controller.view.frame = NSRect(x: 0, y: 0, width: 420, height: 900)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        NativeTestHostLifecycle.observe(window, phase: "sampled")

        let normalID = "chat.session.row.\(targetID.uuidString)"
        let restoreID = "chat.sidebar.archive.restore.\(targetID.uuidString)"
        _ = try requireSidebarAX(normalID, in: window)
        let restoreAbsentBeforeArchive =
            NativeConsumerOwnedAX.hasNoIdentifier(in: window, prefix: restoreID) == true

        try #require(restoreAbsentBeforeArchive)
        #expect(restoreAbsentBeforeArchive)
        // Move through both active presentation domains without changing producer identity.
        chat.setPinned(!initiallyPinned, sessionID: targetID)
        _ = try requireSidebarAX(normalID, in: window)
        chat.setPinned(initiallyPinned, sessionID: targetID)
        _ = try requireSidebarAX(normalID, in: window)
        let toggle = try requireSidebarAX("chat.sidebar.archived.toggle", in: window)
        try #require(NativeConsumerOwnedAX.press(toggle))

        let nextActive = SessionSidebarArchiveConsumer.archive(
            targetID, in: chat, visibleActiveIDs: { visibleActiveIDs(chat) }
        )
        #expect(nextActive == companionID)
        #expect(chat.sessions.map(\.id) == [companionID])
        #expect(SessionSidebarArchiveConsumer.visibleArchivedItems(in: chat).map(\.id) == [targetID])
        let archived = try #require(chat.archivedList.first { $0.id == targetID })
        #expect(archived.session.groupID == group.id)
        #expect(archived.session.messages.map(\.id) == targetMessages)
        #expect(store.loadSession(id: targetID.uuidString) == nil)
        let restore = try requireSidebarAX(restoreID, in: window)
        #expect(NativeConsumerOwnedAX.role(restore) == .button)
        let normalAbsentWhileArchived =
            NativeConsumerOwnedAX.hasNoIdentifier(in: window, prefix: normalID) == true

        try #require(normalAbsentWhileArchived)
        #expect(normalAbsentWhileArchived)

        try #require(NativeConsumerOwnedAX.press(restore))
        _ = try requireSidebarAX(normalID, in: window)
        let restoreAbsentAfterRestore =
            NativeConsumerOwnedAX.hasNoIdentifier(in: window, prefix: restoreID) == true

        try #require(restoreAbsentAfterRestore)
        #expect(restoreAbsentAfterRestore)
        #expect(chat.activeSessionID == targetID)
        #expect(chat.archivedList.isEmpty)
        #expect(Set(chat.sessions.map(\.id)) == Set([companionID, targetID]))
        #expect(chat.sessions.count <= ChatStore.maxSessionListCount)
        #expect(chat.messages.map(\.id) == targetMessages)
        #expect(chat.sessions.first { $0.id == companionID }?.messages.map(\.id) == companionMessages)
        #expect(chat.sessions.first { $0.id == targetID }?.groupID == group.id)
        #expect(store.loadSession(id: targetID.uuidString)?.id == targetID.uuidString)

        let reopened = ChatStore(preferencesDefaults: profile.makeUserDefaults(),
                                 logManager: profile.makeLogManager())
        let reopenedStore = SessionStore(directory: profile.sessionDirectory)
        try #require(reopened.attachPersistence(reopenedStore, badgeStore: badges))
        #expect(reopened.sessionManager?.badgeStore === badges)
        #expect(reopened.archivedList.isEmpty)
        #expect(Set(reopened.sessions.map(\.id)) == Set([companionID, targetID]))
        let reopenedTarget = try #require(reopened.sessions.first { $0.id == targetID })
        let reopenedTargetPayload = reopenedTarget.messages.map { $0.asLLMMessage() }
        #expect(reopenedTarget.messages.count == targetPayload.count)
        #expect(reopenedTargetPayload == targetPayload)
        #expect(stableMessageIDs(in: reopenedTargetPayload) == targetStableIDs)
        #expect(reopened.sessions.first { $0.id == targetID }?.groupID == group.id)
        let reopenedCompanion = try #require(reopened.sessions.first { $0.id == companionID })
        let reopenedCompanionPayload = reopenedCompanion.messages.map { $0.asLLMMessage() }
        #expect(reopenedCompanion.messages.count == companionPayload.count)
        #expect(reopenedCompanionPayload == companionPayload)
        #expect(stableMessageIDs(in: reopenedCompanionPayload) == companionStableIDs)
        #expect(reopened.groups.contains { $0.id == group.id })
    }

    private func stableMessageIDs(in messages: [LLMMessage]) -> [String] {
        let locator = SessionHistoryLocator()
        return messages.enumerated().map {
            locator.messageID(for: $0.element, transcriptIndex: $0.offset)
        }
    }

    private func requireSidebarAX(_ identifier: String, in window: NSWindow) throws -> AnyObject {
        // Bounded same-host observation; no rebuild, restart or missing-tree-as-absence fallback.
        for _ in 0..<12 {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            if let node = NativeConsumerOwnedAX.find(in: window, identifier: identifier) {
                return node
            }
        }
        return try #require(NativeConsumerOwnedAX.find(in: window, identifier: identifier),
                            "same-process sidebar must expose the exact canonical action: \(identifier)")
    }
}
